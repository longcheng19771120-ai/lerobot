#!/usr/bin/env bash
# One-file driver for the SO-101 (or SO-100) workflow: hardware setup -> record -> train -> eval.
# Usage: ./so101.sh <step> [extra lerobot flags...]   (run without arguments for the list of steps)
# Config is read from so101.env next to this script (see so101.env.example).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/so101.env}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # Shell environment wins over the file, so `TASK_NAME=x ./so101.sh record` works.
  _saved_env="$(export -p)"
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  eval "${_saved_env}" 2>/dev/null || true
fi

ROBOT_TYPE="${ROBOT_TYPE:-so101_follower}"
TELEOP_TYPE="${TELEOP_TYPE:-so101_leader}"
FOLLOWER_PORT="${FOLLOWER_PORT:-/dev/ttyACM0}"
LEADER_PORT="${LEADER_PORT:-/dev/ttyACM1}"
FOLLOWER_ID="${FOLLOWER_ID:-my_follower}"
LEADER_ID="${LEADER_ID:-my_leader}"
DEFAULT_CAMERAS="{ front: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 30, fourcc: \"MJPG\"}}"
CAMERAS="${CAMERAS:-${DEFAULT_CAMERAS}}"
TASK_NAME="${TASK_NAME:-my_task}"
TASK_DESC="${TASK_DESC:-Pick up the cube and place it in the box}"
NUM_EPISODES="${NUM_EPISODES:-50}"
EPISODE_TIME_S="${EPISODE_TIME_S:-30}"
RESET_TIME_S="${RESET_TIME_S:-10}"
PUSH_TO_HUB="${PUSH_TO_HUB:-true}"
POLICY_TYPE="${POLICY_TYPE:-act}"
DEVICE="${DEVICE:-cuda}"
BATCH_SIZE="${BATCH_SIZE:-8}"
STEPS="${STEPS:-50000}"
WANDB="${WANDB:-false}"
EVAL_EPISODES="${EVAL_EPISODES:-10}"

# Use `uv run` inside a source checkout, plain commands otherwise (pip install).
if [[ -z "${RUN+x}" ]]; then
  if command -v uv >/dev/null 2>&1 && [[ -f "${SCRIPT_DIR}/../../pyproject.toml" ]]; then
    RUN="uv run --project ${SCRIPT_DIR}/../.."
  else
    RUN=""
  fi
fi

run() {
  echo "+ $*" >&2
  # shellcheck disable=SC2086
  ${RUN} "$@"
}

hf_user() {
  if [[ -z "${HF_USER:-}" ]]; then
    HF_USER="$(NO_COLOR=1 ${RUN} hf auth whoami 2>/dev/null | awk -F': *' 'NR==1 {print $NF}')"
    if [[ -z "${HF_USER}" ]]; then
      echo "Not logged in to Hugging Face. Run \`hf auth login\` or set HF_USER." >&2
      exit 1
    fi
  fi
  echo "${HF_USER}"
}

robot_args=(--robot.type="${ROBOT_TYPE}" --robot.port="${FOLLOWER_PORT}" --robot.id="${FOLLOWER_ID}")
teleop_args=(--teleop.type="${TELEOP_TYPE}" --teleop.port="${LEADER_PORT}" --teleop.id="${LEADER_ID}")
camera_args=(--robot.cameras="${CAMERAS}")

usage() {
  cat <<USAGE
Usage: $0 <step> [extra lerobot flags...]

Hardware (once per arm):
  find-port       Detect the USB port of an arm (run once per arm)
  perms           Give the current user access to both serial ports (Linux, uses sudo)
  find-cameras    List OpenCV cameras and save a test frame from each
  setup-motors    Write motor ids/baudrate on follower then leader
  calibrate       Calibrate follower then leader
  setup           setup-motors + calibrate (pre-assembled kits can skip setup-motors and run calibrate)
  teleop          Teleoperate with cameras shown (sanity check)

Data:
  record          Record \$NUM_EPISODES episodes to \$HF_USER/\$TASK_NAME and push to the Hub
                  (keys: right arrow = next, left arrow = redo, ESC = stop and upload)
  resume          Continue recording into the existing dataset (\$NUM_EPISODES = how many more to add)
  replay [EP]     Replay episode EP (default 0) on the follower
  view            Print the dataset visualizer link

Policy:
  train           Train \$POLICY_TYPE on the dataset and push it to \$HF_USER/\${POLICY_TYPE}_\$TASK_NAME
  resume-train    Resume the last training run from its checkpoint
  eval [PATH]     Run the policy on the robot for \$EVAL_EPISODES episodes, saved as eval_\$TASK_NAME
                  (PATH defaults to the Hub policy; pass a local pretrained_model dir to test a checkpoint)

Config: ${CONFIG_FILE}
USAGE
}

step="${1:-}"
[[ $# -gt 0 ]] && shift

case "${step}" in
  find-port)
    run lerobot-find-port
    ;;
  perms)
    echo "+ sudo chmod 666 ${FOLLOWER_PORT} ${LEADER_PORT}" >&2
    sudo chmod 666 "${FOLLOWER_PORT}" "${LEADER_PORT}"
    ;;
  find-cameras)
    run lerobot-find-cameras opencv
    ;;
  setup-motors)
    run lerobot-setup-motors --robot.type="${ROBOT_TYPE}" --robot.port="${FOLLOWER_PORT}" "$@"
    run lerobot-setup-motors --teleop.type="${TELEOP_TYPE}" --teleop.port="${LEADER_PORT}" "$@"
    ;;
  calibrate)
    run lerobot-calibrate "${robot_args[@]}" "$@"
    run lerobot-calibrate "${teleop_args[@]}" "$@"
    ;;
  setup)
    "$0" setup-motors "$@"
    "$0" calibrate "$@"
    ;;
  teleop)
    run lerobot-teleoperate "${robot_args[@]}" "${teleop_args[@]}" "${camera_args[@]}" \
      --display_data=true "$@"
    ;;
  record | resume)
    extra=()
    [[ "${step}" == "resume" ]] && extra+=(--resume=true)
    run lerobot-record "${robot_args[@]}" "${teleop_args[@]}" "${camera_args[@]}" \
      --dataset.repo_id="$(hf_user)/${TASK_NAME}" \
      --dataset.single_task="${TASK_DESC}" \
      --dataset.num_episodes="${NUM_EPISODES}" \
      --dataset.episode_time_s="${EPISODE_TIME_S}" \
      --dataset.reset_time_s="${RESET_TIME_S}" \
      --dataset.push_to_hub="${PUSH_TO_HUB}" \
      --display_data=true ${extra[@]+"${extra[@]}"} "$@"
    ;;
  replay)
    episode="${1:-0}"
    [[ $# -gt 0 ]] && shift
    run lerobot-replay "${robot_args[@]}" \
      --dataset.repo_id="$(hf_user)/${TASK_NAME}" --dataset.episode="${episode}" "$@"
    ;;
  view)
    echo "https://huggingface.co/spaces/lerobot/visualize_dataset?path=/$(hf_user)/${TASK_NAME}"
    ;;
  train)
    user="$(hf_user)"
    run lerobot-train \
      --dataset.repo_id="${user}/${TASK_NAME}" \
      --policy.type="${POLICY_TYPE}" \
      --policy.device="${DEVICE}" \
      --policy.repo_id="${user}/${POLICY_TYPE}_${TASK_NAME}" \
      --output_dir="outputs/train/${POLICY_TYPE}_${TASK_NAME}" \
      --job_name="${POLICY_TYPE}_${TASK_NAME}" \
      --batch_size="${BATCH_SIZE}" \
      --steps="${STEPS}" \
      --wandb.enable="${WANDB}" "$@"
    ;;
  resume-train)
    run lerobot-train \
      --config_path="outputs/train/${POLICY_TYPE}_${TASK_NAME}/checkpoints/last/pretrained_model/train_config.json" \
      --resume=true "$@"
    ;;
  eval)
    user="$(hf_user)"
    policy_path="${1:-${user}/${POLICY_TYPE}_${TASK_NAME}}"
    [[ $# -gt 0 ]] && shift
    run lerobot-rollout --strategy.type=episodic \
      --policy.path="${policy_path}" \
      "${robot_args[@]}" "${camera_args[@]}" \
      --dataset.repo_id="${user}/eval_${TASK_NAME}" \
      --dataset.single_task="${TASK_DESC}" \
      --dataset.num_episodes="${EVAL_EPISODES}" \
      --dataset.episode_time_s="${EPISODE_TIME_S}" \
      --dataset.reset_time_s="${RESET_TIME_S}" \
      --display_data=true "$@"
    ;;
  "" | -h | --help | help)
    usage
    ;;
  *)
    echo "Unknown step: ${step}" >&2
    usage >&2
    exit 1
    ;;
esac
