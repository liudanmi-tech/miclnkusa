# SSH 登录测试服务器说明

## 服务器信息

| 项目 | 值 |
|------|-----|
| IP | `47.79.254.213` |
| SSH 用户 | `liudanmi` |
| 服务运行用户 | `liudan` |
| 日志路径 | `/home/liudan/gemini-audio-service.log` |
| 服务路径 | `/opt/gemini-audio-service/` |
| SSH 别名 | `gemini-server`（见 `~/.ssh/config`） |

## 本机 SSH 配置

`~/.ssh/config` 中已配置：

```
Host gemini-server
  HostName 47.79.254.213
  User liudan
```

> ⚠️ 注意：`User` 应为 `liudanmi`，不是 `liudan` 或 `admin`。

## 登录方式

### 直连（需要安全组放开本机 IP）

```bash
ssh -i ~/.ssh/id_rsa -o IdentitiesOnly=yes gemini-server
```

### 通过 Google Cloud Shell 中转（推荐，绕过安全组）

1. 打开 [Google Cloud Console](https://console.cloud.google.com)，进入该实例的 Cloud Shell
2. 直接在 Cloud Shell 里执行命令

## 常见问题

### Permission denied (publickey)

**原因 1：ssh-agent 里加载的是别的机器的密钥**

```bash
# 查看当前 agent 加载的密钥
ssh-add -l

# 加载正确的私钥
ssh-add ~/.ssh/id_rsa

# 验证指纹是否匹配
ssh-keygen -lf ~/.ssh/id_rsa.pub
# 应输出：3072 SHA256:2RcEhs8C6bswmbwzemmS6CELzWo+/VPgChTEKHcWIcs ludanmi (RSA)
```

**原因 2：公钥未加入服务器 authorized_keys**

在服务器上执行（需要 sudo）：

```bash
echo "$(cat ~/.ssh/id_rsa.pub)" >> ~/.ssh/authorized_keys
```

若目录不存在：

```bash
sudo mkdir -p /home/liudanmi/.ssh
sudo chmod 700 /home/liudanmi/.ssh
echo "ssh-rsa ..." | sudo tee -a /home/liudanmi/.ssh/authorized_keys
sudo chmod 600 /home/liudanmi/.ssh/authorized_keys
sudo chown -R liudanmi:liudanmi /home/liudanmi/.ssh
```

**原因 3：云平台安全组拦截（最常见）**

日志中看不到任何连接记录（`/var/log/auth.log` 无对应条目），说明连接被安全组防火墙拦截，根本没有到达 sshd。

解决方式：去云平台控制台，将 SSH 入站规则的源 IP 改为 `0.0.0.0/0`，或添加当前客户端 IP。

### 连接超时 / 日志中无记录

说明被安全组拦截，参考上方"原因 3"。

## 查日志常用命令

```bash
# 查特定 session 的日志
sudo grep -i "<session_id>" /home/liudan/gemini-audio-service.log | tail -100

# 实时监控日志
sudo tail -f /home/liudan/gemini-audio-service.log

# 查服务进程
ps aux | grep -E "uvicorn|python|fastapi" | grep -v grep
```

## 服务器用户说明

| 用户 | 说明 |
|------|------|
| `liudanmi` | 可 SSH 登录、有 sudo 权限 |
| `liudan` | 服务运行用户，日志在其 home 目录 |
| `admin` | 目录存在（`/home/admin`）但系统中无此用户，不可登录 |
