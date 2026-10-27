# CPSY 1197 preprocessing pipeline

You will not need to write any new code. The full walkthrough, with figures
from the real data and the exact console output to compare against, is in
**[TUTORIAL.md](TUTORIAL.md)**. Start there.

| File | What it does |
|---|---|
| `cpsy1197_check.m` | One command that says if you can start or what is missing. |
| `cpsy1197_preprocess.m` | The full preprocessing pipeline. |
| `cpsy1197_report.m` | Prints the numbers for your submission. |
| `TUTORIAL.md` | The walkthrough. Start here. |

## First run

```matlab
addpath /path/to/fieldtrip                      % replace this with your actual fieldtrip path
cpsy1197_check                                  % must print READY

out = cpsy1197_preprocess('data/1/1_P3.set');   % participant 1 of the P3b, everyone's first run
```

Your own participants come from one of three ERP CORE experiments: the N170,
the P3b or the N400. The pipeline recognises the experiment from the file
name (`12_N170.set`, `12_P3.set`, `12_N400.set`) and prints it at the top of
the run, with the trials it will cut. You do not type any event codes.

## Your homework

Artefact corrections at three different stages for all of your assigned participants

**Stage 4, bad channels.** The pipeline opens the whole recording in a
browser. Page through it, decide which channels are broken, and type their
names. A channel with blinks in it is not broken. The channels you name are
taken out before the ICA and the reference, and rebuilt afterwards.

**Stage 5, ICA components.** The pipeline shows component topographies, time
courses, and each component's correlation with the eye channels. Name the
components to remove: blinks, and horizontal eye movements. Usually one or
two, sometimes three, rarely more; if you cannot say what artifact a
component is, leave it in.

**Stage 9, which trials are bad.** A fixed rule first removes the trials in
which some channel swings by more than the ERP CORE authors' median limit for
your experiment: 125 uV for the P3b, 100 uV for the N170 and the N400. Then you page through every trial that is left, one per screen, mark the bad ones with the b key and finish with q. The report prints the list of all removed trials, by the rule and by hand. The tutorial says what a bad trial looks like.

## Saving and submitting

```matlab
cpsy1197_report(out, 'Your Name');                  % paste the block it prints
```

The pipeline saves two files next to the raw data. The cleaned data, for
example `data/1/1_P3_clean.mat`, stays on your machine. The small summary
file, for example `data/1/1_P3_summary.mat`, holds your decision log and the
per-condition averages. That one goes to Canvas.

## If something breaks

There is a Troubleshooting section. If your problem is not there, post the exact error text on the Canvas
Questions thread. Somebody else has almost certainly hit the same thing, and
answering a classmate counts toward participation.


