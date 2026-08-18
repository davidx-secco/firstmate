# Cursor effort ladder - end-to-end evidence

fm-spawn was driven for real at every effort level with a fake tmux pane (so the
literal launch command is captured instead of starting a worker) and the REAL
`cursor-agent` on PATH, so fm-spawn's catalog validation ran against the live
Cursor catalog rather than a stub.

    $ cursor-agent --version
    2026.08.04-aaa8809

## Live catalog (grok rows, `cursor-agent --list-models`)

    cursor-grok-4.5-low - Cursor Grok 4.5 Low
    cursor-grok-4.5-medium - Cursor Grok 4.5 Medium
    cursor-grok-4.5-high - Cursor Grok 4.5
    cursor-grok-4.6-low - Cursor Grok 4.6 Low
    cursor-grok-4.6-medium - Cursor Grok 4.6 Medium
    cursor-grok-4.6-high - Cursor Grok 4.6
    cursor-grok-4.6-xhigh - Cursor Grok 4.6 Extra High
    (plus a -fast sibling for each rung; there is no cursor-grok-4.6-max)

Confirms: the 4.6 family publishes a real low/medium/high/xhigh ladder, xhigh is
its top rung, and the 4.5 low/medium ids are still listed and selectable.

## Effort -> launched model, before and after this change

| `--effort` | base e3ffb00 launch | this change launch |
| --- | --- | --- |
| low | `--model 'cursor-grok-4.5-low'` | `--model 'cursor-grok-4.6-low'` |
| medium | `--model 'cursor-grok-4.5-medium'` | `--model 'cursor-grok-4.6-medium'` |
| high | `--model 'cursor-grok-4.5-high'` | `--model 'cursor-grok-4.6-high'` |
| xhigh | `--model 'cursor-grok-4.5-high'` (collapsed) | `--model 'cursor-grok-4.6-xhigh'` |
| max | `--model 'cursor-grok-4.5-high'` (collapsed) | `--model 'cursor-grok-4.6-xhigh'` |

Every run exited 0, meaning each derived id passed validation against the live
catalog. No launch contains a `-fast` id.

## Actual captured launch command (xhigh)

    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
      -u CURSOR_INVOKED_AS '/Users/davidxiao/.local/bin/cursor-agent' \
      --trust --yolo --model 'cursor-grok-4.6-xhigh' --workspace '<task worktree>' \
      "$('<repo>/bin/fm-operational-input.sh' encode launch-brief < '<brief.md>')"

## Explicit legacy model still wins

    $ fm-spawn.sh <id> <project> --model cursor-grok-4.5-low --effort xhigh
    exit 0 -> --model 'cursor-grok-4.5-low'

The effort ladder does not upgrade or remap an explicitly requested 4.5 id.

## Mutation check of the new ladder test

Breaking the medium rung in bin/fm-spawn.sh (medium -> cursor-grok-4.6-high) makes
tests/fm-spawn-dispatch-profile.test.sh fail:

    not ok - meta missing model=cursor-grok-4.6-medium

The rung was restored immediately; the worktree is clean.
