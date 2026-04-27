在Amazon EKS上部署Hermes Agent：基于Kata Containers的企业级AI Agent沙箱实践

摘要：利用Kata Containers在EKS上运行Hermes Agent，实现VM级别隔离的AI Agent沙箱

目录

01 容器环境下AI Agent Sandbox的需求与挑战
02 为什么选择Hermes Agent
03 整体架构
04 模型对接
05 Kata Hypervisor选型
06 存储方案
07 安全架构
08 部署步骤
09 可观测性
10 从OpenClaw迁移
11 资源清理
12 总结

## 容器环境下AI Agent Sandbox的需求与挑战

Agent Sandbox需要运行Python脚本、操作文件系统、调用shell命令、安装依赖包，这些操作要求一个完整的运行时环境。在企业环境中，这意味着需要为每个Agent提供一个独立的、受控的计算沙箱。容器是承载这类工作负载的自然选择，但在实际落地过程中需要解决以下几个核心问题。

**隔离粒度。** 传统容器共享宿主机内核。如果Agent发生了逃逸，理论上可以逃逸到宿主机，进而影响同节点上的所有其他Agent。在多租户场景下，发生安全事件，一个用户的Agent可能访问到另一个用户的数据。Linux namespace和cgroup能够覆盖多数隔离需求，但"多数"在安全领域是不够的。

**生命周期管理。** Agent沙箱的生命周期与用户会话绑定，随用户上线创建、离线释放。部分场景对启动速度要求极高，例如用户发送一条消息后，沙箱需要在毫秒级完成初始化并开始执行代码，冷启动延迟直接影响用户体验。这要求底层支持warm pool（预热待命的沙箱实例池）和template（标准化沙箱模板，包含预装环境和配置），使沙箱创建尽可能走热路径。同时，沙箱之间必须保持严格的状态隔离，销毁后不能残留任何数据。

**模型对接。** Agent需要调用LLM完成推理。生产环境中不应让每个沙箱Pod直接持有模型API的凭据，credential泄露的影响面不可控。需要一个中间层统一处理认证、路由、限流和监控。

**持久化存储。** Agent具有状态数据，包括配置文件、会话历史、技能库、记忆系统。沙箱重启后状态不能丢失，但沙箱删除时需要彻底清理。持久化、隔离和IO性能三者需要同时满足。

## 为什么选择Hermes Agent

[Hermes Agent](https://github.com/nousresearch/hermes-agent) 是Nous Research开发的自进化AI Agent框架，定位为OpenClaw的下一代替代方案（内置`hermes claw migrate`迁移工具）。相比OpenClaw，Hermes Agent在以下方面有显著增强：

**自进化能力。** Hermes Agent具备闭环学习机制——在使用过程中自动创建和改进"技能"（Skills），跨会话持久化记忆，并逐步构建用户模型。不是简单地执行一次性任务，而是越用越好。

**多平台消息网关。** 原生支持超过15个消息平台：Telegram、Discord、Slack、WhatsApp、Signal、Matrix、Mattermost、Email、SMS、钉钉、企业微信、微信、飞书、QQ Bot等。通过`hermes gateway run`统一启动，无需为每个平台单独部署。

**灵活的终端后端。** 支持6种代码执行环境：local、Docker、SSH、Modal、Daytona、Singularity。在Kata沙箱内可选择local后端直接执行，或通过Docker后端实现Docker-in-Docker的双重隔离。

**丰富的模型支持。** 原生支持20+模型提供商（Anthropic、OpenAI、OpenRouter、Nous Portal、Gemini、硅基流动等），也可通过LiteLLM统一代理。

**OpenAI兼容API。** 内置API Server（端口8642）暴露`/v1/chat/completions`和`/v1/responses`等标准端点，可对接Open WebUI、LobeChat等前端。

**Web Dashboard。** 内置管理面板（端口9119），提供配置管理、会话浏览、环境变量编辑等功能。

## 整体架构

- **Amazon EKS集群**：托管Kubernetes控制平面，core节点组（m5.xlarge）承载系统工作负载
- **Karpenter**：按需弹性供给c8i/m8i实例（嵌套KVM），沙箱Pod触发时自动拉起，空闲1分钟内回收
- **Kata Containers**：为每个沙箱Pod提供VM级别隔离，支持QEMU和Cloud Hypervisor
- **LiteLLM Proxy**：OpenAI兼容的API网关，统一对接Amazon Bedrock、硅基流动等模型提供商
- **Hermes Agent Pod**：每个用户会话对应一个独立Pod，运行Gateway进程和内置Dashboard
- **Agent Sandbox Controller**：CRD驱动的沙箱生命周期管理，支持warm pool和模板化创建
- **Prometheus + Grafana**：可观测性栈，包含预置的LiteLLM监控面板

与OpenClaw架构的关键差异在于：Hermes Agent的Gateway进程同时处理多个消息平台的连接，每个Pod即是一个完整的Agent实例，包含消息处理、技能执行、记忆管理和API服务等全部功能。

## 模型对接

Hermes Agent支持两种模型对接模式，可根据部署场景灵活选择。

### 模式一：通过LiteLLM统一代理（推荐）

LiteLLM在架构中充当统一的模型网关，对上层暴露OpenAI兼容API，对下层同时对接多个模型提供商。认证采用EKS Pod Identity机制，LiteLLM的ServiceAccount绑定IAM Role，运行时自动获取临时凭据，沙箱Pod本身不持有任何credential。

LiteLLM Helm配置示例：

```yaml
model_list:
- litellm_params:
    aws_region_name: us-east-1
    model: bedrock/us.anthropic.claude-opus-4-6-v1
  model_name: claude-opus-4-6
- litellm_params:
    model: openai/Qwen/Qwen2.5-72B-Instruct
    api_base: https://api.siliconflow.cn/v1
    api_key: sk-123456
  model_name: qwen-72b
```

Hermes Agent端的`config.yaml`配置：

```yaml
model:
  default: "openai/claude-opus-4-6"
  provider: "custom"
  base_url: "http://litellm.litellm.svc.cluster.local:4000"
  api_key: "<generated-litellm-key>"

auxiliary:
  vision:
    model: "openai/claude-opus-4-6"
  compression:
    model: "openai/claude-opus-4-6"
```

### 模式二：Hermes Agent直连模型提供商

对于单租户或开发环境，可跳过LiteLLM，让Hermes Agent直连模型API：

```yaml
model:
  default: "anthropic/claude-opus-4.6"
  provider: "anthropic"
  # API key通过Kubernetes Secret注入环境变量ANTHROPIC_API_KEY
```

或通过OpenRouter聚合多模型：

```yaml
model:
  default: "anthropic/claude-opus-4.6"
  provider: "openrouter"
  base_url: "https://openrouter.ai/api/v1"
  # API key通过环境变量OPENROUTER_API_KEY注入
```

推荐在生产环境中使用LiteLLM模式：credential统一管理、限流监控、模型切换对沙箱透明。

## Kata Hypervisor选型

Kata Containers支持三种Hypervisor，各有适用场景。

### 特性对比

| 特性 | QEMU | Cloud Hypervisor (CLH) | Firecracker |
|---|---|---|---|
| 生态成熟度 | 最成熟 | 活跃发展 | 成熟 |
| virtio-fs | 支持 | 支持 | 不支持 |
| CPU/内存热插拔 | 支持 | 支持 | 不支持 |
| 启动速度 | ~500ms+ | ~200ms | ~125ms |
| 内存开销 | ~30-130MB/VM | ~10-20MB/VM | ~5MB/VM |
| GPU直通 | 支持 | 不支持 | 不支持 |
| 机密计算 | 支持(TDX/SEV-SNP) | 不支持 | 不支持 |

### 推荐方案：Cloud Hypervisor为主，QEMU保底

**CLH是AI Agent沙箱的最优默认选择。** 理由：

1. **兼容性无忧**：Guest VM运行完整Linux内核，Agent执行任意Python代码、shell命令、pip/apt安装，零兼容风险
2. **virtio-fs支持**：容器镜像通过共享文件系统传递，无需像Firecracker那样配置devmapper
3. **热插拔支持**：可动态调整VM的CPU和内存，适应Agent负载波动
4. **性能显著优于QEMU**：启动速度约快2.5倍，内存开销约低3-6倍
5. **零迁移成本**：从QEMU切换只需更改RuntimeClass，基础设施配置不变

```yaml
# Kata配置：同时启用QEMU和CLH
shims:
  disableAll: true
  qemu:
    enabled: true
  clh:
    enabled: true
```

**Firecracker适用于高密度场景**（单节点需要部署数百个沙箱），但需要额外配置devmapper snapshotter和静态资源分配。详见[隔离后端技术分析](./isolation-backends-analysis.md)。

## 存储方案

### Amazon EBS

每个Hermes Agent沙箱Pod挂载一个2Gi的EBS gp3卷至`/opt/data`，对应Hermes Agent的持久化主目录。该目录包含：

```
/opt/data/
  .env              # API密钥（通过Secret注入）
  config.yaml       # Agent配置
  SOUL.md           # 人格定义文件
  sessions/         # 会话历史（SQLite + JSON轨迹）
  memories/         # 持久化记忆（MEMORY.md, USER.md）
  skills/           # 学习到的技能
  logs/             # 运行日志
  cron/             # 定时任务
  workspace/        # 工作区
```

需要注意单节点EBS挂载数量存在上限。不同EC2实例类型支持的EBS卷数量不同，这直接影响单节点的沙箱部署密度。

EBS卷对三种Kata Hypervisor均兼容——EBS是块设备，通过virtio-blk直接传递给Guest VM，不依赖virtio-fs。

### 利用Amazon EFS的Access Point实现隔离

EBS受限于单AZ挂载且单节点挂载数量有上限。当沙箱密度较高或需要跨AZ调度时，Amazon EFS是替代方案。EFS的Access Point机制天然适合Agent沙箱的隔离需求：每个沙箱Pod分配一个独立的Access Point，配置独立的root directory、POSIX user identity（UID/GID）和目录权限。

注意：EFS与Firecracker兼容性较差（EFS基于NFS协议，不是块设备），如果使用Firecracker作为Hypervisor，建议选择EBS。

## 安全架构

### Pod与宿主机隔离

Kata Containers为每个Pod启动独立VM，运行独立的Guest内核。在此基础上，通过以下配置进一步加固：

```yaml
securityContext:
  runAsUser: 10000
  runAsGroup: 10000
  capabilities:
    drop: ["ALL"]
  allowPrivilegeEscalation: false
```

Hermes Agent容器默认以`hermes`用户（UID 10000）运行，与Kata VM隔离形成双层防护。

### 网络隔离

Kata在tc网络模式（默认模式），Kubernetes NetworkPolicy在该模式下正常生效。建议为Hermes Agent Pod配置出站白名单：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hermes-sandbox-egress
spec:
  podSelector:
    matchLabels:
      app: hermes-sandbox
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: litellm
      ports:
        - port: 4000
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - port: 443
        - port: 80
```

### 凭据管理

整个架构中不存在长期凭据：

- **Bedrock**：LiteLLM通过Pod Identity获取临时凭据
- **LiteLLM API Key**：动态生成，设置30天有效期
- **消息平台Token**（Telegram、飞书、钉钉等）：通过Kubernetes Secret管理，定期轮换
- **Hermes API Server Key**：通过Secret注入`API_SERVER_KEY`环境变量

## 部署步骤

### 前置条件

- AWS CLI
- kubectl
- Terraform
- Helm v3.x

### Step 1：克隆仓库并执行部署脚本

项目基于Terraform管理全部基础设施。`install.sh`封装了Terraform和Helm的执行流程，创建的资源包括：VPC及子网、EKS集群及core节点组、Karpenter（含c8i/m8i EC2NodeClass和NodePool）、Kata Containers（kata-deploy）、LiteLLM Proxy（含Pod Identity配置）、Prometheus和Grafana。

```bash
git clone https://github.com/hitsub2/aws-eks-kata-for-agents
cd aws-eks-kata-for-agents
chmod +x install.sh
./install.sh
```

支持自定义Region和集群名称：

```bash
./install.sh --region ap-southeast-1 --cluster-name my-hermes
```

完整部署过程约15-20分钟。

### Step 2：获取LiteLLM API Key

集群就绪后，通过LiteLLM的master key为每一个Sandbox生成专用的API Key：

```bash
MASTER_KEY=$(kubectl get secret litellm-masterkey -n litellm \
  -o jsonpath='{.data.masterkey}' | base64 -d)

LITELLM_API_KEY=$(kubectl run -n litellm gen-key --rm -i \
  --restart=Never --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"models": ["claude-opus-4-6"], "duration": "30d"}' \
  | grep -o '"key":"[^"]*"' | cut -d'"' -f4)
```

### Step 3：验证Bedrock连通性

```bash
kubectl run -n litellm test --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s -X POST http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "claude-opus-4-6", "messages": [{"role": "user", "content": "Hi"}], "max_tokens": 20}'
```

收到正常的模型回复即表明Bedrock连接已建立。

### Step 4：准备Hermes Agent配置

创建ConfigMap和Secret：

```bash
# 创建config.yaml ConfigMap
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-config
  namespace: default
data:
  config.yaml: |
    model:
      default: "openai/claude-opus-4-6"
      provider: "custom"
      base_url: "http://litellm.litellm.svc.cluster.local:4000"
    terminal:
      backend: "local"
      timeout: 180
    compression:
      enabled: true
      threshold: 0.50
  SOUL.md: |
    你是一个企业级AI助手，运行在安全的沙箱环境中。
    你可以执行代码、分析数据、管理文件。
    始终遵循安全最佳实践，不执行危险操作。
EOF

# 创建Secret（API keys）
kubectl create secret generic hermes-secrets \
  --from-literal=LITELLM_API_KEY="${LITELLM_API_KEY}" \
  --from-literal=API_SERVER_KEY="$(openssl rand -hex 32)" \
  --from-literal=FEISHU_APP_ID="${FEISHU_APP_ID:-}" \
  --from-literal=FEISHU_APP_SECRET="${FEISHU_APP_SECRET:-}" \
  --from-literal=TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
  --from-literal=DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
```

### Step 5：部署Hermes Agent沙箱Pod

```yaml
# hermes-sandbox.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-data
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: gp3
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: hermes-sandbox
  labels:
    app: hermes-sandbox
spec:
  runtimeClassName: kata-clh    # Cloud Hypervisor，可选kata-qemu
  containers:
  - name: hermes
    image: nousresearch/hermes-agent:latest
    command: ["gateway", "run"]
    ports:
    - containerPort: 8642
      name: api
    - containerPort: 9119
      name: dashboard
    env:
    - name: HERMES_UID
      value: "10000"
    - name: HERMES_GID
      value: "10000"
    envFrom:
    - secretRef:
        name: hermes-secrets
    volumeMounts:
    - name: data
      mountPath: /opt/data
    - name: config
      mountPath: /opt/data/config.yaml
      subPath: config.yaml
    - name: config
      mountPath: /opt/data/SOUL.md
      subPath: SOUL.md
    resources:
      requests:
        cpu: "1"
        memory: "1Gi"
      limits:
        cpu: "2"
        memory: "2Gi"
    livenessProbe:
      httpGet:
        path: /health
        port: 8642
      initialDelaySeconds: 30
      periodSeconds: 10
    readinessProbe:
      httpGet:
        path: /health
        port: 8642
      initialDelaySeconds: 10
      periodSeconds: 5
    securityContext:
      capabilities:
        drop: ["ALL"]
      allowPrivilegeEscalation: false
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: hermes-data
  - name: config
    configMap:
      name: hermes-config
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-sandbox
spec:
  selector:
    app: hermes-sandbox
  ports:
  - name: api
    port: 8642
    targetPort: 8642
  - name: dashboard
    port: 9119
    targetPort: 9119
```

```bash
kubectl apply -f hermes-sandbox.yaml
```

### Step 6：验证

```bash
# 检查Pod状态
kubectl get pod hermes-sandbox

# 查看日志，确认Gateway启动和消息平台连接
kubectl logs -f hermes-sandbox

# 测试API Server
kubectl run test-hermes --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s http://hermes-sandbox:8642/health/detailed

# 访问Dashboard（本地端口转发）
kubectl port-forward pod/hermes-sandbox 9119:9119
# 浏览器打开 http://localhost:9119
```

在飞书/Telegram/Discord等平台向Bot发送消息，确认能够收到正常回复。

## 可观测性

Prometheus和Grafana随Terraform一同部署完成。

```bash
terraform output -raw grafana_admin_password
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

### Hermes Agent监控

Hermes Agent内置`/health/detailed`端点，返回丰富的运行状态信息。建议配置Prometheus ServiceMonitor抓取该端点，监控以下指标：

- 活跃会话数和会话缓存命中率
- 消息处理延迟（按平台维度）
- 工具调用成功率和耗时
- 技能执行频次
- 内存和Session存储大小

LiteLLM层面的监控（请求量、Token消耗、延迟、费用）使用项目预置的Grafana Dashboard。

## 从OpenClaw迁移

Hermes Agent内置了OpenClaw迁移工具，可自动导入：

- `SOUL.md`人格定义
- 记忆系统数据
- 技能库
- 命令白名单
- 消息平台配置
- API密钥
- TTS资源
- 工作区指令

迁移步骤：

```bash
# 在Hermes Agent Pod内执行
kubectl exec -it hermes-sandbox -- hermes claw migrate

# 或在本地迁移后同步到PVC
hermes claw migrate
# 将~/.hermes目录内容同步到PVC
```

迁移工具会自动检测`~/.openclaw`（以及`~/.clawdbot`、`~/.moltbot`等旧名称）目录。

## 资源清理

```bash
kubectl delete pod hermes-sandbox
kubectl delete pvc hermes-data
kubectl delete configmap hermes-config
kubectl delete secret hermes-secrets
terraform destroy
```

## 总结

AI Agent对运行环境的要求与传统容器工作负载有本质区别：不可预测的代码执行、多租户间的强隔离需求、毫秒级的沙箱启停、有状态的持久化管理。

Hermes Agent作为新一代AI Agent框架，带来了自进化技能、跨会话记忆、多平台消息网关和OpenAI兼容API等关键能力。结合Kata Containers的VM级别隔离，每个沙箱Pod运行在独立的Guest内核中，攻击面从整个Linux内核syscall缩小到Hypervisor虚拟设备接口。

在Hypervisor选型上，我们推荐Cloud Hypervisor作为默认选择——它提供与QEMU相同的功能完备性（virtio-fs、热插拔），同时具备约2.5倍的启动速度优势和3-6倍的内存开销优势。对于需要极致沙箱密度的场景，Firecracker以额外的运维复杂度为代价，提供~125ms启动和~5MB/VM的极低开销。gVisor因syscall兼容性风险，不推荐用于运行任意代码的AI Agent沙箱。

完整的Terraform代码和配置见：[aws-eks-kata-for-agents](https://github.com/hitsub2/aws-eks-kata-for-agents)
