seed=1234
pretrained_checkpoint="/blob/users/conglli/project/bert_with_pile/checkpoint/bert-pile-0.336B-iters-2M-lr-1e-4-min-1e-5-wmup-10000-dcy-2M-sty-linear-gbs-1024-mbs-16-gpu-64-zero-0-mp-1-pp-1-nopp"

###############################################################################
### Main configs
### The main configs are from Megatron-LM paper
### https://arxiv.org/abs/1909.08053. Choose based on your desired model size
### or build your own configs.
seq_len=512

## From Table 6 in https://arxiv.org/abs/1909.08053.
task="MNLI"
global_batch_size=128
lr=1e-5
epochs=10

train_data="/blob/data/GlueData/MNLI/train.tsv"
valid_data="/blob/data/GlueData/MNLI/dev_matched.tsv \
            /blob/data/GlueData/MNLI/dev_mismatched.tsv"

## Adjust based on number of GPUs.
batch_size=16

## BERT 110M (same config as original BERT-Base model)
## This config is not included in Megatron-LM paper
# model_size=0.11
# num_layers=12
# hidden_size=768
# num_attn_heads=12

## BERT 336M (same config as original BERT-Large model)
model_size=0.336
num_layers=24
hidden_size=1024
num_attn_heads=16

## BERT 1.3B
# model_size=1.3
# num_layers=24
# hidden_size=2048
# num_attn_heads=32

## BERT 3.9B
# model_size=3.9
# num_layers=48
# hidden_size=2560
# num_attn_heads=40
###############################################################################
### Parallelism configs
## Model parallelism, 1 is no MP
mp_size=1

## Pipeline parallelism. To disable PP, set pp_size to 1 and no_pp to true.
## Currently pipeline parallelism is not supported for BERT model: DeepSpeed's
## pipeline parallelism is only integrated with the GPT case, and currently
## DeepSpeed is not integrated with Megatron's own pipeline parallelism.
pp_size=1
no_pp="true"

## ZeRO stage
zero_stage=0
###############################################################################
### Misc configs
log_interval=10
eval_iters=50
eval_interval=100
save_interval=500000

## Activation checkpointing saves GPU memory, but reduces training speed
# activation_checkpoint="true"
activation_checkpoint="false"
###############################################################################
vocab_file="bert-large-uncased-vocab.txt"
if [ ! -f "$vocab_file" ]; then
    wget https://s3.amazonaws.com/models.huggingface.co/bert/bert-large-uncased-vocab.txt
fi

jobname="${task}-bsz${global_batch_size}-lr${lr}-epochs${epochs}-seed${seed}"
checkpoint_path="${pretrained_checkpoint}-finetune/${jobname}"
mkdir -p ${checkpoint_path}

template_json="ds_config_bert_TEMPLATE.json"
config_json="ds_config_bert_bsz${global_batch_size}_mbsz${batch_size}_log${log_interval}_zero${zero_stage}.json"
if [[ $zero_stage -gt 0 ]]; then
sed "s/CONFIG_BATCH_SIZE/${global_batch_size}/" ${template_json} \
    | sed "s/CONFIG_MBSIZE/${batch_size}/" \
    | sed "s/LOG_INTERVAL/${log_interval}/" \
    | sed "s/ZERO_STAGE/${zero_stage}/" \
    | sed "s/PRESCALE_GRAD/false/" \
    | sed "s/CONFIG_FP16_ENABLED/true/" \
    | sed "s/CONFIG_BF16_ENABLED/false/" \
      > ${config_json}
else
sed "s/CONFIG_BATCH_SIZE/${global_batch_size}/" ${template_json} \
    | sed "s/CONFIG_MBSIZE/${batch_size}/" \
    | sed "s/LOG_INTERVAL/${log_interval}/" \
    | sed "s/ZERO_STAGE/${zero_stage}/" \
    | sed "s/PRESCALE_GRAD/true/" \
    | sed "s/CONFIG_FP16_ENABLED/true/" \
    | sed "s/CONFIG_BF16_ENABLED/false/" \
      > ${config_json}
fi

options=" \
    --finetune \
    --deepspeed \
    --deepspeed_config ${config_json} \
    --zero-stage ${zero_stage} \
    --task ${task} \
    --seed ${seed} \
    --train-data ${train_data} \
    --valid-data ${valid_data} \
    --tokenizer-type BertWordPieceLowerCase \
    --vocab-file ${vocab_file} \
    --epochs ${epochs} \
    --pretrained-checkpoint ${pretrained_checkpoint} \
    --tensor-model-parallel-size ${mp_size} \
    --pipeline-model-parallel-size ${pp_size} \
    --num-layers ${num_layers} \
    --hidden-size ${hidden_size} \
    --num-attention-heads ${num_attn_heads} \
    --global-batch-size ${global_batch_size} \
    --micro-batch-size ${batch_size} \
    --lr ${lr} \
    --lr-decay-style linear \
    --lr-warmup-fraction 0.065 \
    --seq-length ${seq_len} \
    --max-position-embeddings ${seq_len} \
    --save-interval ${save_interval} \
    --save ${checkpoint_path} \
    --log-interval ${log_interval} \
    --eval-interval ${eval_interval} \
    --eval-iters ${eval_iters} \
    --weight-decay 1.0e-1 \
    --fp16"

if [ "${activation_checkpoint}" = "true" ]; then
options="${options} \
    --checkpoint-activations \
    --deepspeed-activation-checkpointing"
fi

if [[ "${no_pp}" = "true" ]]; then
options="${options} \
    --no-pipeline-parallel"
fi

# After the fine-tuning finishes, you can find the dev set accuracy numbers by
# "grep -e "overall:" -e "metrics for" ${checkpoint_path}/output.log"
deepspeed ../../../../tasks/main.py ${options} &> ${checkpoint_path}/output.log
