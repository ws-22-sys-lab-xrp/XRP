#!/bin/bash

if [ "$(uname -r)" !=  "5.12.0-xrp+" ]; then
    printf "Not in XRP kernel. Please run the following commands to boot into XRP kernel:\n"
    printf "    sudo grub-reboot \"Advanced options for Ubuntu>Ubuntu, with Linux 5.12.0-xrp+\"\n"
    printf "    sudo reboot\n"
    exit 1
fi

SCRIPT_PATH=`realpath $0`
EVAL_PATH=`dirname $SCRIPT_PATH`
BASE_DIR=`realpath $EVAL_PATH/../..`
BPFKV_PATH="$BASE_DIR/BPF-KV"
UTILS_PATH="$BASE_DIR/utils"

# Specialized BPF-KV
BPFKV_IO_URING_OPEN_LOOP_PATH="$BASE_DIR/Specialized-BPF-KV/io_uring_open_loop"
BPFKV_SPDK_OPEN_LOOP_PATH="$BASE_DIR/Specialized-BPF-KV/spdk_open_loop"

DEV_NAME="/dev/nvme0n1"
NUM_OPS=5000000
LAYER=6
NUM_THREADS=12

if [ $# -ne 2 ] && [ $# -ne 3 ]; then
    printf "Usage: $0 <operations per second (min: 60000, max: 720000)> <mode (xrp, spdk)> <block device (optional, default: $DEV_NAME)>\n"
    exit 1
fi
REQ_PER_SEC=$1
if [ $REQ_PER_SEC -lt 60000 ] || [ $REQ_PER_SEC -gt 720000 ]; then
    printf "Operations per second $REQ_PER_SEC is out of range. Min: 60000. Max: 720000.\n"
    exit 1
fi
MODE="$2"
if [ $MODE != "xrp" ] && [ $MODE != "spdk" ]; then
    printf "MODE $MODE is invalid. Available options are: xrp, spdk.\n"
    exit 1
fi
if [ ! -z $3 ]; then
    DEV_NAME=$3
fi

printf "LAYER=$LAYER\n"
printf "MODE=$MODE\n"
printf "DEV_NAME=$DEV_NAME\n"
printf "NUM_OPS=$NUM_OPS\n"
printf "NUM_THREADS=$NUM_THREADS\n"
printf "REQ_PER_SEC=$REQ_PER_SEC\n"

# Check whether BPF-KV is built
if [ ! -e "$BPFKV_PATH/simplekv" ]; then
    printf "Cannot find BPF-KV binary. Please build BPF-KV first.\n"
    exit 1
fi

# Disable CPU frequency scaling
$UTILS_PATH/disable_cpu_freq_scaling.sh

# Reset SPDK
$UTILS_PATH/spdk_reset.sh

# Create result folder
mkdir -p $EVAL_PATH/result

if [ $MODE == "xrp" ]; then
    pushd $BPFKV_IO_URING_OPEN_LOOP_PATH
    # Unmont disk (io_uring is measured with raw block device)
    $UTILS_PATH/unmount_disk.sh $DEV_NAME
    # Load database
    printf "Creating a BPF-KV database file with $LAYER layers of index...\n"
    sudo ./db-bpf --load $LAYER

    printf "Evaluating BPF-KV with $LAYER index lookup, $NUM_THREADS threads, $REQ_PER_SEC ops/s, and XRP...\n"
    # Warmup first
    sudo ./db-bpf --run $LAYER $NUM_OPS $NUM_THREADS 100 0 0 $(($REQ_PER_SEC / $NUM_THREADS))

    sudo ./db-bpf --run $LAYER $NUM_OPS $NUM_THREADS 100 0 0 $(($REQ_PER_SEC / $NUM_THREADS)) | tee $EVAL_PATH/result/$REQ_PER_SEC-ops-xrp.txt
    popd
elif [ $MODE == "spdk" ]; then
    pushd $BPFKV_SPDK_OPEN_LOOP_PATH
    # Bind disk to UIO driver so that SPDK can use it
    $UTILS_PATH/spdk_setup.sh $DEV_NAME
    # Load database
    printf "Creating a BPF-KV database file with $LAYER layers of index...\n"
    sudo ./db --mode load --layer $LAYER

    printf "Evaluating BPF-KV with $LAYER index lookup, $NUM_THREADS threads, $REQ_PER_SEC ops/s, and SPDK...\n"
    # Warmup first
    sudo ./db --mode run --layer $LAYER --thread $NUM_THREADS --request $NUM_OPS --rate $(($REQ_PER_SEC / $NUM_THREADS)) --cache 0

    sudo ./db --mode run --layer $LAYER --thread $NUM_THREADS --request $NUM_OPS --rate $(($REQ_PER_SEC / $NUM_THREADS)) --cache 0 | tee $EVAL_PATH/result/$REQ_PER_SEC-ops-spdk.txt
    # Rebind disk to kernel NVMe driver
    $UTILS_PATH/spdk_reset.sh
    popd
fi

printf "Done. Results are stored in $EVAL_PATH/result\n"
