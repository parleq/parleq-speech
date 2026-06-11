// SystemPrefixCache — pure key + LRU logic for the on-device KV prefix cache.
//
// The on-device cleanup provider re-prefills the same ~1.5K-token cleanup
// system prompt on every dictation, which dominates time-to-first-token
// (~800–900ms). The KV prefix cache prefills ONLY the system-prompt prefix
// once, then clones that KV state per utterance and extends it with the
// per-utterance user suffix — turning the per-call prefill from "whole system
// prompt + user turn" into "user turn only".
//
// This file holds the parts that are pure and trivially unit-testable:
//
//   • `SystemPrefixCacheKey` — the cache key. A prefix is identified by the
//     (checkpoint id, SHA-256 of the exact system-prefix text) pair. The hash
//     means any change to the prompt — a dictionary edit, a per-app transform
//     suffix — produces a different key and naturally invalidates the old
//     entry. We hash rather than store the text so keys stay small and no
//     transcript-shaped content is retained.
//
//   • `PrefixCacheLRU` — a tiny fixed-capacity LRU map. The actual KV state
//     (GPU-resident `[KVCache]`) is the value type, parameterised here so the
//     map can be tested with a trivial stand-in value. Eviction returns the
//     evicted value so the owner can drop it explicitly.
//
// The cache itself (which holds GPU memory and must be dropped on idle unload)
// lives inside `ResidencyManager`'s actor isolation, alongside the
// `ModelContainer` — see `ResidencyManager.swift`. Only the system-prefix KV
// state is ever cached here; per-utterance user/assistant turns are NEVER
// retained (HARD INVARIANT #5 — no conversation state persists between calls).

import CryptoKit
import Foundation

/// Identifies a cached system-prompt prefix by checkpoint + a SHA-256 of the
/// exact prefix text. Equatable/Hashable so it can key the LRU.
public struct SystemPrefixCacheKey: Equatable, Hashable, Sendable {
    /// The checkpoint id the prefix was prefilled against (e.g.
    /// "mlx-community/gemma-4-E4B-it-qat-4bit"). A cache entry is only valid for
    /// the exact model that produced its KV state.
    public let checkpoint: String

    /// Lowercase hex SHA-256 of the exact system-prefix text. Storing the hash
    /// rather than the text keeps keys small and avoids retaining prompt
    /// content; a single character change yields a different key (natural
    /// invalidation on dictionary / transform changes).
    public let prefixHash: String

    /// Build a key from the checkpoint id and the raw system-prefix text.
    public init(checkpoint: String, prefixText: String) {
        self.checkpoint = checkpoint
        self.prefixHash = Self.sha256Hex(prefixText)
    }

    /// Lowercase hex SHA-256 of a string's UTF-8 bytes.
    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// A small fixed-capacity least-recently-used map.
///
/// Insertion and lookup both mark an entry most-recently-used. When inserting a
/// new key at capacity, the least-recently-used entry is evicted and returned
/// so the caller can release its (GPU-resident) value. `Value` is generic so
/// the eviction/recency logic can be unit-tested with a trivial value type
/// while the production cache stores `[KVCache]`.
///
/// Not thread-safe on its own; the production instance is confined to
/// `ResidencyManager`'s actor isolation.
public struct PrefixCacheLRU<Value> {
    /// Maximum number of live entries. Per the approved design this is small
    /// (4): per-app preset transforms vary the prefix suffix, so a handful of
    /// distinct prefixes can be live, but the working set is tiny.
    public let capacity: Int

    // Parallel storage: `entries` maps key → value, `order` lists keys from
    // least- to most-recently-used (last element is hottest). The map is bounded
    // by `capacity` so the linear scans on `order` are over ≤4 elements.
    private var entries: [SystemPrefixCacheKey: Value] = [:]
    private var order: [SystemPrefixCacheKey] = []

    public init(capacity: Int) {
        precondition(capacity > 0, "PrefixCacheLRU capacity must be positive")
        self.capacity = capacity
    }

    /// Current number of live entries.
    public var count: Int { entries.count }

    /// Keys currently held, least- to most-recently-used.
    public var keysByRecency: [SystemPrefixCacheKey] { order }

    /// Look up a key, marking it most-recently-used on a hit. Returns nil on miss.
    public mutating func get(_ key: SystemPrefixCacheKey) -> Value? {
        guard let value = entries[key] else { return nil }
        touch(key)
        return value
    }

    /// Whether a key is present, WITHOUT changing recency (for tests / probes).
    public func contains(_ key: SystemPrefixCacheKey) -> Bool {
        entries[key] != nil
    }

    /// Insert or replace a value for `key`, marking it most-recently-used.
    ///
    /// - Returns: the value evicted to make room (the least-recently-used entry)
    ///   when inserting a brand-new key at capacity, otherwise nil. Replacing an
    ///   existing key never evicts.
    @discardableResult
    public mutating func insert(_ key: SystemPrefixCacheKey, _ value: Value) -> Value? {
        if entries[key] != nil {
            entries[key] = value
            touch(key)
            return nil
        }

        var evicted: Value?
        if entries.count >= capacity, let lru = order.first {
            evicted = entries.removeValue(forKey: lru)
            order.removeFirst()
        }

        entries[key] = value
        order.append(key)
        return evicted
    }

    /// Remove all entries, returning the values so the caller can release them.
    /// Used on idle unload, when the KV state's backing GPU memory is dropped.
    @discardableResult
    public mutating func removeAll() -> [Value] {
        let values = order.compactMap { entries[$0] }
        entries.removeAll()
        order.removeAll()
        return values
    }

    /// Move `key` to the most-recently-used position. Caller guarantees presence.
    private mutating func touch(_ key: SystemPrefixCacheKey) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
    }
}
