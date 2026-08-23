# Proxy Server Initialization

一套用于 **Ubuntu VPS 自动化初始化、代理服务部署、TLS 自动续签、节点监控接入 Prometheus 的基础设施初始化框架。**

目标：

> 新开一台 Ubuntu VPS，只需要执行一次初始化脚本，即可完成稳定运行环境部署。

---

## Features

### System Bootstrap

自动完成：

- 基础软件安装
- Swap 配置
- journald 日志限制
- 系统参数优化
- 基础环境检查


### Docker Runtime

自动安装并配置：

- Docker Engine
- Docker 服务启动
- Docker 环境检查


### ACME Certificate

支持：

- acme.sh
- Let's Encrypt
- Cloudflare DNS Challenge
- 泛域名证书


自动完成：

```
Certificate Request
        |
        |
        v
/root/.acme.sh
        |
        |
        v
/etc/ssl/<domain>
```

证书安装后自动触发消费者 reload。


支持监控：

- 证书存在
- 证书有效期
- 证书私钥匹配
- 自动续签任务状态


---

# 3x-ui Deployment

自动部署：

```
3x-ui
 |
 Docker
 |
 HTTPS Panel
 |
 ACME Certificate
```

特性：

- Docker CLI 部署
- 不依赖 Docker Compose
- 自动随机 Panel Path
- 自动随机 Panel Port
- 自动生成管理员账号密码
- 自动挂载 TLS 证书


部署完成：

```bash
cat /root/vps-bootstrap-result.env
```

查看：

```
PANEL_URL
PANEL_USERNAME
PANEL_PASSWORD
```


---

# Node Exporter Monitoring

自动部署：

```
Prometheus
        |
        |
 node_exporter
        |
        |
 Textfile Collector
        |
        |
 Custom Metrics
```


支持输出：

- 主机状态
- Docker 状态
- 证书状态
- 3x-ui状态
- REALITY端口状态


示例：

```
vpsnode_cert_days_remaining 89

vpsnode_service_up{
service="3xui"
} 1
```


---

# Prometheus Integration

自动生成：

```
vps-bootstrap-output/

├── node-exporter-target.json
└── instance-rules.yml
```


可以直接导入中央 Prometheus：

```yaml
file_sd_configs:
  - files:
      - targets/*.json
```


---

# Installation


## 1. Download

```bash
git clone https://github.com/<your-name>/proxy-server-initialization.git

cd proxy-server-initialization
```


## 2. Run

```bash
bash install.sh
```


首次运行会询问：

```
Instance name
Domain
ACME Email
Cloudflare Token
Prometheus Metric Prefix
```


不会内置任何个人信息。


---

# Requirements

支持：

| OS | Status |
|-|-|
| Ubuntu 20.04 | ✅ |
| Ubuntu 22.04 | ✅ |
| Ubuntu 24.04 | ✅ |


最低建议：

```
CPU: 1 Core
RAM: 1GB
Disk: 10GB
```


推荐：

```
RAM >= 1GB
Swap >= 1GB
```


---

# Security Design

设计原则：

## No Secret In Repository

禁止提交：

```
Cloudflare Token
Private Key
Panel Password
Certificate
Runtime Config
```


所有敏感信息：

```
/etc/vps-bootstrap/
```

权限：

```
600
root only
```


---

# Idempotent Design

支持重复执行：

```bash
bash install.sh
```


不会重复：

- 创建重复证书
- 创建重复容器
- 覆盖已有配置


适用于：

- 新机器初始化
- 灾难恢复
- VPS迁移


---

# Diagnostic


执行：

```bash
bash diagnose.sh
```


输出：

```
/root/vps-bootstrap-diagnostic.log
```


包含：

- 网络状态
- Docker状态
- ACME状态
- TLS状态
- systemd状态
- Prometheus指标


自动隐藏：

- Token
- Password
- Secret


---

# Validation


执行：

```bash
bash verify.sh
```


成功：

```
STATUS: SUCCESS
```


---

# Architecture


```
             User
              |
              |
        install.sh
              |
              |
        run.sh
              |
 ------------------------------------------------
 |          |          |          |              |
System    Docker     ACME      3x-ui       Monitor
 |
 |
Node Exporter
 |
 |
Prometheus
 |
 |
Alertmanager
```


---

# Roadmap

## v1.x

- VPS初始化
- 代理服务
- TLS
- Prometheus


## Future

计划：

- 多节点批量初始化
- Ansible模式
- Web控制台
- 自动节点注册
- 多云平台支持


---

# License

MIT License