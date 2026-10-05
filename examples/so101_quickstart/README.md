# SO-101 quickstart driver

`so101.sh` wraps the SO-101 / SO-100 workflow from [`AGENT_GUIDE.md`](../../AGENT_GUIDE.md) §4 so ports, ids,
cameras and dataset names are typed once in a config file instead of on every command.

```bash
uv sync --locked --extra feetech --extra core_scripts --extra training   # motors + record + train
cd examples/so101_quickstart
cp so101.env.example so101.env      # edit ports, cameras, task name/description
./so101.sh find-port                 # once per arm, put the result in so101.env
./so101.sh find-cameras              # put camera indices in so101.env
./so101.sh setup                     # motor ids + calibration, follower then leader
./so101.sh teleop                    # sanity check
./so101.sh record                    # record and push $HF_USER/$TASK_NAME
./so101.sh view                      # visualizer link, check the data before training
./so101.sh train                     # train ACT and push $HF_USER/act_$TASK_NAME
./so101.sh eval                      # run the policy on the robot via lerobot-rollout
```

To fine-tune [FLUX 3 Action](../../docs/source/flux3.mdx) instead of ACT, record with two cameras named
`scene` and `wrist`, install `uv sync --locked --extra feetech --extra core_scripts --extra training --extra flux3` plus a torch-matched NATTEN
wheel, then run `POLICY_TYPE=flux3 ./so101.sh train` and `POLICY_TYPE=flux3 ./so101.sh eval`.

Any extra flags are forwarded to the underlying `lerobot-*` command, e.g. `./so101.sh train --steps=20000`.
Shell variables override the config file, e.g. `TASK_NAME=stack_cubes ./so101.sh record`.
On macOS the script defaults to `DEVICE=mps` and has no default ports (they are `/dev/tty.usbmodem...`).
With Homebrew FFmpeg 9, torchcodec cannot load it and LeRobot falls back to pyav for video decoding
(works, slower); `brew install ffmpeg@8` restores torchcodec.
Inside a source checkout the commands run through `uv run`; set `RUN=` to call them directly.
