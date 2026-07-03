// Usage: node scripts/contrast.mjs '#d97706' '#311551'
const hex = (h) => { const n = h.replace('#',''); return [0,2,4].map(i=>parseInt(n.slice(i,i+2),16)/255); };
const lin = (c) => c <= 0.03928 ? c/12.92 : ((c+0.055)/1.055)**2.4;
const L = (rgb) => { const [r,g,b]=rgb.map(lin); return 0.2126*r+0.7152*g+0.0722*b; };
const ratio = (a,b)=>{ const la=L(hex(a)), lb=L(hex(b)); const [hi,lo]=[Math.max(la,lb),Math.min(la,lb)]; return (hi+0.05)/(lo+0.05); };
const [fg,bg] = process.argv.slice(2);
if(!fg||!bg){ console.error('usage: contrast.mjs <fg> <bg>'); process.exit(2); }
console.log(ratio(fg,bg).toFixed(2));
