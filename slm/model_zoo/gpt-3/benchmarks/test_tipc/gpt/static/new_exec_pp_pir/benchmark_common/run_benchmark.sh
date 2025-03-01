#!/usr/bin/env bash

# Copyright (c) 2022 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Test training benchmark for a model.
# Usage：bash benchmark/run_benchmark.sh ${model_item} ${fp_item} ${dp_degree} ${mp_degree} ${pp_degree} ${micro_batch_size} ${global_batch_size} ${run_mode} ${device_num} ${use_sharding}
function _set_params(){
    model_item=${1:-"model_item"}   # (必选) 模型 item
    fp_item=${2:-"fp16"}            # (必选) o1|o2|o3
    dp_degree=${3:-"1"}             # (必选) dp数据并行度
    mp_degree=${4:-"1"}             # (必选) mp数据并行度
    pp_degree=${5:-"1"}             # (必选) pp数据并行度
    micro_batch_size=${6:-"2"}      # (必选) micro_batch_size = local_batch_size / pp_degree
    global_batch_size=${7:-"16"}    # （必选）global_batch_size
    run_mode=${8:-"DP"}             # (必选) MP模型并行|DP数据并行|PP流水线并行|混合并行DP1-MP1-PP1|DP2-MP8-PP2|DP1-MP8-PP4|DP4-MP8-PP1
    device_num=${9:-"N1C1"}         # (必选) 使用的卡数量，N1C1|N1C8|N4C32 （4机32卡）
    profiling=${PROFILING:-"false"}      # (必选) Profiling  开关，默认关闭，通过全局变量传递
    model_repo="PaddleNLP"          # (必选) 模型套件的名字
    speed_unit="tokens/s"         # (必选)速度指标单位
    skip_steps=0                  # (必选)解析日志，跳过模型前几个性能不稳定的step
    keyword="ips:"                 # (必选)解析日志，筛选出性能数据所在行的关键字
    convergence_key="loss:"        # (可选)解析日志，筛选出收敛数据所在行的关键字 如：convergence_key="loss:"
    sharding_degree=${10:-"1"}      # (可选)
    sharding_stage=${11:-"1"}       # (可选)sharding case
    level=${12:-"o1"}               # o1|o2|o3

    if [[ $FLAGS_enable_pir_api == "1" || $FLAGS_enable_pir_api == "True" ]]; then
        if [ ${level} == "o3" ]; then
            level="o2"
            echo "amp level changed to o2 in pir mode"
        else
            echo "amp level is o3"
        fi
    else
        echo "FLAGS_enable_pir_api = 0"
    fi

    local_batch_size=${13:-"8"}    # （可选）本地batch size
    schedule_mode=${14:-"1F1B"}    # （可选）schedule mode
    base_batch_size=$global_batch_size

    # 以下为通用执行命令，无特殊可不用修改
    model_name=${model_item}_bs${global_batch_size}_${fp_item}_${run_mode}  # (必填) 且格式不要改动,与竞品名称对齐
    device=${CUDA_VISIBLE_DEVICES//,/ }
    arr=(${device})
    num_gpu_devices=${#arr[*]}
    run_log_path=${TRAIN_LOG_DIR:-$(pwd)}  # （必填） TRAIN_LOG_DIR  benchmark框架设置该参数为全局变量
    profiling_log_path=${PROFILING_LOG_DIR:-$(pwd)}  # （必填） PROFILING_LOG_DIR benchmark框架设置该参数为全局变量
    speed_log_path=${LOG_PATH_INDEX_DIR:-$(pwd)}
    #
    train_log_file=${run_log_path}/${model_repo}_${model_name}_${device_num}_log
    profiling_log_file=${profiling_log_path}/${model_repo}_${model_name}_${device_num}_profiling
    speed_log_file=${speed_log_path}/${model_repo}_${model_name}_${device_num}_speed

    OUTPUT_PATH=${run_log_path}/output
}

function _train(){
    batch_size=${local_batch_size}  # 如果模型跑多卡单进程时,请在_train函数中计算出多卡需要的bs

    if [ -d $OUTPUT_PATH ]; then
        rm -rf $OUTPUT_PATH
    fi
    mkdir $OUTPUT_PATH

    echo "current CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}, model_name=${model_name}, device_num=${device_num}, is profiling=${profiling}"

    if [ ${profiling} = "true" ];then
        add_options="--profiler_options=\"batch_range=[10,20];state=GPU;tracer_option=Default;profile_path=model.profile\""
        log_file=${profiling_log_file}
    else
        add_options=""
        log_file=${train_log_file}
    fi

    train_cmd="-o Model.hidden_dropout_prob=0 \
               -o Model.attention_probs_dropout_prob=0 \
               -o Model.use_recompute=True \
               -o Model.hidden_size=3072 \
               -o Global.local_batch_size=8 \
               -o Global.micro_batch_size=${micro_batch_size} \
               -o Distributed.dp_degree=${dp_degree} \
               -o Distributed.mp_degree=${mp_degree} \
               -o Distributed.pp_degree=${pp_degree} \
               -o Distributed.sharding.sharding_degree=${sharding_degree} \
               -o Distributed.sharding.sharding_stage=${sharding_stage} \
               -o Engine.mix_precision.level=${level} \
               -o Engine.max_steps=100 \
               -o Engine.eval_freq=100000 \
               -o Distributed.pipeline.schedule_mode=${schedule_mode} \
               -o Profiler_auto.memory_stats=True \
               -o Engine.verbose=3 \
               -o Engine.logging_freq=1 "

    if [ ${PADDLE_TRAINER_ID} ]
    then
        PADDLE_RANK_OPTION=" --rank ${PADDLE_TRAINER_ID}"
    else
        PADDLE_RANK_OPTION=""
    fi
    # 以下为通用执行命令，无特殊可不用修改
    case ${run_mode} in
    DP1-MP1-PP8-SD1-stage1) echo "run run_mode: ${run_mode}"
        train_cmd="python -m paddle.distributed.launch --log_dir=./mylog --devices=0,1,2,3,4,5,6,7 ${PADDLE_RANK_OPTION}\
            tools/auto.py -c ppfleetx/configs/nlp/gpt/auto/pretrain_gpt_6.7B_sharding16.yaml \
            ${train_cmd}"
        workerlog_id=7
        ;;
    DP1-MP2-PP4-SD1-stage1) echo "run run_mode: ${run_mode}"
        train_cmd="python -m paddle.distributed.launch --log_dir=./mylog --devices=0,1,2,3,4,5,6,7 ${PADDLE_RANK_OPTION}\
            tools/auto.py -c ppfleetx/configs/nlp/gpt/auto/pretrain_gpt_6.7B_sharding16.yaml \
            ${train_cmd}"
        workerlog_id=6
        ;;
    DP2-MP1-PP4-SD2-stage1|DP2-MP1-PP4-SD2-stage2| \
    DP2-MP2-PP2-SD2-stage1|DP2-MP2-PP2-SD2-stage2) echo "run run_mode: ${run_mode}"
        train_cmd="python -m paddle.distributed.launch --log_dir=./mylog --devices=0,1,2,3,4,5,6,7 ${PADDLE_RANK_OPTION}\
            tools/auto.py -c ppfleetx/configs/nlp/gpt/auto/pretrain_gpt_6.7B_sharding16.yaml \
            ${train_cmd}"
        workerlog_id=3
        ;;
    DP1-MP8-PP2-SD1-stage1) echo "run run_mode: ${run_mode}"
        # fp32
        train_cmd="python -m paddle.distributed.launch --log_dir=./mylog --devices=0,1,2,3,4,5,6,7 ${PADDLE_RANK_OPTION}\
            tools/auto.py -c ppfleetx/configs/nlp/gpt/auto/pretrain_gpt_13B_sharding8.yaml \
            -o Model.hidden_dropout_prob=0 \
            -o Model.attention_probs_dropout_prob=0 \
            -o Model.use_recompute=True \
            -o Global.micro_batch_size=${micro_batch_size} \
            -o Global.local_batch_size=16 \
            -o Distributed.dp_degree=${dp_degree} \
            -o Distributed.mp_degree=${mp_degree} \
            -o Distributed.pp_degree=${pp_degree} \
            -o Distributed.sharding.sharding_degree=${sharding_degree} \
            -o Engine.mix_precision.enable=False \
            -o Engine.max_steps=100 \
            -o Engine.eval_freq=100000 \
            -o Distributed.pipeline.schedule_mode=${schedule_mode} \
            -o Profiler_auto.memory_stats=True \
            -o Engine.verbose=3 \
            -o Engine.logging_freq=1 "
        workerlog_id=0
        ;;
    DP1-MP8-PP4-SD1-stage1) echo "run run_mode: ${run_mode}"
        train_cmd="python -m paddle.distributed.launch --log_dir=./mylog --devices=0,1,2,3,4,5,6,7 ${PADDLE_RANK_OPTION}\
            tools/auto.py -c ppfleetx/configs/nlp/gpt/auto/pretrain_gpt_13B_sharding8.yaml \
            -o Model.hidden_dropout_prob=0 \
            -o Model.attention_probs_dropout_prob=0 \
            -o Model.hidden_size=6144 \
            -o Model.num_attention_heads=48 \
            -o Model.num_layers=64 \
            -o Model.use_recompute=True \
            -o Global.micro_batch_size=${micro_batch_size} \
            -o Global.local_batch_size=4 \
            -o Distributed.dp_degree=${dp_degree} \
            -o Distributed.mp_degree=${mp_degree} \
            -o Distributed.pp_degree=${pp_degree} \
            -o Distributed.sharding.sharding_degree=${sharding_degree} \
            -o Engine.mix_precision.enable=False \
            -o Engine.max_steps=100 \
            -o Engine.eval_freq=100000 \
            -o Distributed.pipeline.schedule_mode=${schedule_mode} \
            -o Profiler_auto.memory_stats=True \
            -o Engine.verbose=3 \
            -o Engine.logging_freq=1 "
        workerlog_id=0
        ;;
    *) echo "choose run_mode "; exit 1;
    esac
    cd ../
    echo "train_cmd: ${train_cmd}  log_file: ${log_file}"
    timeout 120m ${train_cmd} > ${log_file} 2>&1
    if [ $? -ne 0 ];then
        echo -e "${model_name}, FAIL"
    else
        echo -e "${model_name}, SUCCESS"
    fi
    #kill -9 `ps -ef|grep 'python'|awk '{print $2}'`
    if [ ${device_num} != "N1C1" -a -d mylog ]; then
        case_path=$PWD && cd - && mkdir -p mylog      # PaddleNLP/model_zoo/gpt-3/benchmarks
        cp -r ${case_path}/mylog/workerlog.* ./mylog/
        rm ${log_file}
        cp ${case_path}/mylog/workerlog.${workerlog_id} ${log_file}
    fi
}

export PYTHONPATH=$(dirname "$PWD"):$PYTHONPATH
export FLAGS_fraction_of_gpu_memory_to_use=0.1  # 避免预分配的的显存影响实际值观测
export FLAGS_embedding_deterministic=1          # 1：关闭随机性（测试精度时为1）；0：打开随机性（测性能时为0），当前默认为1
export FLAGS_cudnn_deterministic=1              # 1：关闭随机性（测试精度时为1）；0：打开随机性（测性能时为0），当前默认为1
export FLAGS_enable_pir_in_executor=true        # 开启PIR
unset CUDA_MODULE_LOADING
env |grep FLAGS

source ${BENCHMARK_ROOT}/scripts/run_model.sh   # 在该脚本中会对符合benchmark规范的log使用analysis.py 脚本进行性能数据解析;如果不联调只想要产出训练log可以注掉本行,提交时需打开
_set_params $@
#_train       # 如果只产出训练log,不解析,可取消注释
_run     # 该函数在run_model.sh中,执行时会调用_train; 如果不联调只产出训练log可以注掉本行,提交时需打开
