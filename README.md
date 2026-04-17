# Antigravity + Codex 共享框架部署仓库

这个仓库用于把当前的 Antigravity + Codex 共享框架整理成一套可以迁移、可恢复、适合放在 GitHub 的部署项目。

它解决的是两件事：

1. 在新电脑上把共享框架“装起来”
2. 把已有记忆、工作流快照、项目 overlay 一起“搬过去”

## 仓库定位

这个仓库本身不是你的完整运行时目录，也不是私有状态数据库。

它更像一套“部署控制面”，主要包含：

- 安装脚本
- 配置模板
- 状态导出/恢复脚本
- 迁移清单
- 说明文档

建议把这个仓库放在 GitHub，优先使用私有仓库。

## 当前目录结构

```text
antigravity-codex-deployment/
  README.md
  .gitignore
  docs/
    portable-deployment-plan.md
    path-migration-checklist.md
  install/
    env.template
    paths.template.yaml
    write_paths_config.py
    render_framework_config.py
    install_everything.sh
    doctor.sh
    export_state.sh
    restore_state.sh
    templates/
      projects-registry.template.yaml
      hook-policy.template.yaml
      runtime-map.template.yaml
  manifests/
    framework-include.txt
    state-include.txt
    exclude.txt
```

## 这套仓库能做什么

### 1. 安装共享框架骨架

通过 `install/install_everything.sh`，可以在目标机器上：

- 生成 `paths.yaml`
- 运行 `bootstrap_global_agent_fabric.py`
- 渲染机器专属的 `runtime-map.yaml`、`hook-policy.yaml`、`projects/registry.yaml`
- 做基础健康检查

### 2. 导出当前状态

通过 `install/export_state.sh`，可以把以下内容打包导出：

- `global-agent-fabric/memory/*.ndjson`
- `global-agent-fabric/workflows/imported/`
- 各项目的 `.agents/`

### 3. 恢复已有状态

通过 `install/restore_state.sh`，可以把状态包恢复到新的机器目录中。

### 4. 做健康检查

通过 `install/doctor.sh`，可以验证：

- 关键框架文件是否齐全
- `preflight_check.py` 是否能通过
- `sync_all.py` 是否能跑通最小同步链

## 使用前提

请先确保目标机器满足这些条件：

- 已安装 `python3`
- 已安装 `zsh`
- 已有或准备创建 `global-agent-fabric` 目标目录
- 目标机器上有可访问的：
  - Gemini 规则文件
  - Antigravity MCP 配置
  - awesome-skills 目录

如果你的目标是“完整迁移”，还需要准备一份状态包。

## 快速开始

### 第一步：准备环境配置

复制模板：

```bash
cp install/env.template install/.env.local
```

然后按目标机器实际情况修改 `install/.env.local`。

最关键的变量有：

- `AGF_FRAMEWORK_SOURCE_ROOT`
- `AGF_GLOBAL_ROOT`
- `AGF_AWESOME_SKILLS_ROOT`
- `AGF_GEMINI_RULE`
- `AGF_ANTIGRAVITY_MCP_CONFIG`
- `AGF_PROJECT_MCP_HUB`
- `AGF_PROJECT_4`

说明：

- `AGF_FRAMEWORK_SOURCE_ROOT` 表示“拿来引导安装的现有框架源码位置”
- `AGF_GLOBAL_ROOT` 表示“目标机器最终要生成的共享框架根目录”

如果你是在当前机器先做迁移演练，这两个路径可以不同。

### 第二步：仅安装框架

```bash
zsh install/install_everything.sh install/.env.local install/paths.yaml
```

执行后会完成：

- 路径配置渲染
- 框架 bootstrap
- YAML 配置渲染
- 健康检查

### 第三步：导出当前状态

如果你要把当前机器的上下文一起带走：

```bash
zsh install/export_state.sh install/.env.local ./state-export.tar.gz
```

### 第四步：安装并恢复状态

如果目标机器已经拿到状态包：

```bash
zsh install/install_everything.sh install/.env.local install/paths.yaml ./state-export.tar.gz
```

这会在安装框架后自动恢复：

- 共享记忆
- workflow snapshots
- 项目 `.agents` overlay

## 常用脚本说明

### `install/install_everything.sh`

作用：

- 安装最小可用框架
- 可选恢复状态包
- 最后执行 `doctor.sh`

参数：

```bash
zsh install/install_everything.sh <env-file> <paths-output> [state-archive]
```

### `install/export_state.sh`

作用：

- 按 `manifests/state-include.txt` 导出状态
- 自动跳过 `manifests/exclude.txt` 中的内容

参数：

```bash
zsh install/export_state.sh <env-file> <output-archive>
```

### `install/restore_state.sh`

作用：

- 把状态包恢复到目标机器目录

参数：

```bash
zsh install/restore_state.sh <env-file> <state-archive>
```

### `install/doctor.sh`

作用：

- 检查关键文件
- 验证 `preflight_check.py`
- 验证 `sync_all.py`

参数：

```bash
zsh install/doctor.sh <env-file>
```

## 如何放到 GitHub

建议步骤如下：

1. 在本地进入这个仓库目录
2. 初始化 Git 仓库
3. 检查 `.gitignore` 是否符合你的需求
4. 提交后推送到 GitHub 私有仓库

示例：

```bash
cd /Users/david_chen/Desktop/antigravity-codex-deployment
git init
git add .
git commit -m "Initial portable deployment project"
```

然后：

- 在 GitHub 创建一个新的私有仓库
- 把本地仓库推送上去

## 哪些内容建议不要直接放 GitHub

以下内容建议保持本地或单独加密保存：

- `install/.env.local`
- 真实 token / API key
- 导出的状态包
- 任何包含私人项目上下文的敏感记忆

如果后面你决定长期使用这套部署方式，我建议下一步给状态包增加默认加密。

## 当前完成度

目前已经完成：

- 路径模板化主链
- 机器专属 YAML 渲染
- 最小可用安装链
- 状态导出与恢复链

目前还适合继续加强的部分：

- 状态包默认加密
- GitHub 发布说明进一步精简
- 自动初始化 GitHub 仓库或发布脚本

## 建议工作流

如果你要在另一台电脑恢复这套系统，建议按这个顺序：

1. 克隆本仓库
2. 配置 `install/.env.local`
3. 准备状态包
4. 运行 `install/install_everything.sh`
5. 检查 `doctor.sh` 输出
6. 再开始使用 Codex / Antigravity
