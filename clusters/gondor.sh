# Example adapted from agent0. Set EXP_GPU=a100, h100, or h200.
case "${EXP_GPU:-a100}" in
    a100) EXP_PARTITION=gpu; EXP_CONSTRAINT=gpu-a100 ;;
    h100) EXP_PARTITION=gpu-large; EXP_CONSTRAINT=gpu-h100 ;;
    h200) EXP_PARTITION=gpu-large; EXP_CONSTRAINT=gpu-h200 ;;
    *) echo 'EXP_GPU must be a100, h100, or h200.' >&2; return 2 ;;
esac
EXP_GRES="gpu:${EXP_GPU:-a100}:1"
