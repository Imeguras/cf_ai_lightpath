// Records the README walkthrough (docs/demo.gif) against a running Lightpath:
//   make demo-gif   (needs chromium and ffmpeg; uses a few AI neurons)
// Scripted walkthrough of Lightpath, captured as numbered PNG frames.
import { browser, sleep } from "./cdp.mjs";
const base = process.argv[2], out = process.argv[3];
const b = await browser({ width: 1280, height: 800 });
let n = 0;
const frame = async () => b.shot(`${out}/f${String(n++).padStart(4, "0")}.png`);
const hold = async (ms) => { for (let t = 0; t < ms; t += 400) { await frame(); await sleep(400); } };
const until = async (js, max = 90000, every = 2000) => {
  for (let t = 0; t < max; t += every) { await frame(); if (await b.eval(js)) return true; await sleep(every); }
  return false;
};
const smooth = async (y) => { await b.eval(`window.scrollTo({top:${y},behavior:'smooth'})`); await hold(1200); };
const ofs = (sel, pad = 90) => b.eval(`(()=>{const e=document.querySelector(${JSON.stringify(sel)});return e?e.getBoundingClientRect().top+window.scrollY-${pad}:0})()`);

// 1. The evidence page: the newest set (ZFS working again).
await b.go(base + "/", 3500);
await hold(2400);
// 2. Pick the recorded ZFS outage from the dropdown.
await b.eval(`(()=>{const s=document.querySelector('form.lp-setpick select');s.value='zfs-down-2026-11-04';s.dispatchEvent(new Event('change',{bubbles:true}))})()`);
await sleep(1500);
await hold(2400);
await smooth(await ofs('.lp-diagnosis[data-rule="zfs-pools-unavailable"]'));
await hold(2400);
// 3. The runbook under the top cause.
await smooth(await ofs('.lp-diagnosis[data-rule="zfs-pools-unavailable"] .lp-runbook', 160));
await hold(2000);
// 4. Suggest a fix: the scored ranking and the runbook go to the triage Workflow.
await smooth(await ofs('.lp-diagnosis[data-rule="zfs-pools-unavailable"] .lp-suggest', 420));
await b.eval(`document.querySelector('.lp-diagnosis[data-rule="zfs-pools-unavailable"] .lp-suggest button').click()`);
await hold(1200);
await until(`!!document.querySelector('.lp-diagnosis[data-rule="zfs-pools-unavailable"] .lp-suggest .lp-ai, .lp-diagnosis[data-rule="zfs-pools-unavailable"] .lp-suggest .lp-notice')`);
await smooth(await ofs('.lp-diagnosis[data-rule="zfs-pools-unavailable"] .lp-suggest', 380));
await hold(4400);
// 5. Chat, with memory.
await b.go(base + "/chat", 3000);
await hold(1200);
await b.eval(`(()=>{const t=document.querySelector('form.lp-ask textarea');t.value='Why does kubelet keep restarting on my server?';t.dispatchEvent(new Event('input',{bubbles:true}))})()`);
await hold(1200);
await b.eval(`document.querySelector('form.lp-ask').requestSubmit()`);
await hold(1200);
await until(`!!document.querySelector('.lp-msg--assistant, .lp-chat .lp-notice')`);
await hold(4400);
// 6. Arch news against the installed packages.
await b.go(base + "/news", 3000);
await b.eval(`[...document.querySelectorAll('button')].find(x=>x.textContent.includes('Update digest'))?.click()`);
await hold(1200);
await until(`!!document.querySelector('.lp-news__items li, .lp-news .lp-notice') && !document.querySelector('button[disabled]')`);
await hold(4800);
b.close();
console.log("frames", n);
