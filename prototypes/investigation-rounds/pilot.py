"""One frozen release investigation, with a single-agent control. No tools or live pane input."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
output = Path(sys.argv[1])
output.mkdir(exist_ok=True, parents=True)
release = "f9ce54c"
fix = "186d70e"
ancestor = subprocess.run(["git", "merge-base", "--is-ancestor", fix, release], cwd=root)
if ancestor.returncode not in (0, 1):
    raise RuntimeError("Cannot resolve release ancestry")
delta = subprocess.check_output(["git", "cherry", release, fix, "121235d"], cwd=root, text=True).strip()
sources = {
    "A": f"git merge-base --is-ancestor {fix} {release} exited {ancestor.returncode}",
    "B": f"git cherry {release} {fix} 121235d returned {delta}",
}
questions = {"A": "Is the specified commit an ancestor of the release?", "B": "Does git cherry find an equivalent patch upstream?"}

def probe(model, keys):
    prompt = "For each supplied question return a JSON object keyed by its letter, with a boolean yes/no answer as the value. No prose, tools or Markdown.\n" + "\n".join(f"{k}. {questions[k]} Evidence: {sources[k]}" for k in keys)
    if model == "opus":
        cmd = ["claude", "-p", "--model", "opus", "--tools", "", "--no-session-persistence", "--output-format", "json", prompt]
    else:
        cmd = ["codex", "exec", "--model", "gpt-6.2-sol", "-c", 'model_reasoning_effort="low"', "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check", "--json", prompt]
    start = time.monotonic()
    proc = subprocess.run(cmd, cwd=output, capture_output=True, text=True, timeout=180)
    if proc.returncode:
        raise RuntimeError(f"{model} failed: {proc.stderr[-240:]}")
    if model == "opus":
        event = json.loads(proc.stdout)
        answer, usage = event["result"], event["usage"]
    else:
        events = [json.loads(l) for l in proc.stdout.splitlines() if l.startswith("{")]
        answer = [e["item"]["text"] for e in events if e.get("item", {}).get("type")=="agent_message" and e["type"]=="item.completed"][-1]
        usage = next(e["usage"] for e in events if e["type"]=="turn.completed")
    data = json.loads(answer.strip().removeprefix("```json").removesuffix("```").strip())
    expected = {"A": ancestor.returncode == 0, "B": delta.startswith("- ")}
    return dict(model=model, answers=data, verified=set(data)==set(keys) and all(data[k] is expected[k] for k in keys), seconds=round(time.monotonic()-start,2), usage=usage)

if __name__=="__main__":
    control = probe("sol", "AB")
    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=2) as pool:
        branches = list(pool.map(probe, ["sol","opus"], ["A","B"]))
    result = dict(sources=sources,control=control,branches=branches,round_seconds=round(time.monotonic()-start,2))
    (output/"pilot.json").write_text(json.dumps(result,indent=2)+"\n")
    print(control["verified"], [b["verified"] for b in branches], control["seconds"], result["round_seconds"])
