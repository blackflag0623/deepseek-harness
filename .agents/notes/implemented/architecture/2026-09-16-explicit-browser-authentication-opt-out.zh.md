# Agent Note: 显式浏览器认证退出配置

Status: implemented

[English](2026-09-16-explicit-browser-authentication-opt-out.md) | 中文

## Problem

Web Host 的统一浏览器认证保护其工具型 API，但有些运维人员把 loopback 服务器放在独立认证的传输层之后，不希望进行第二次 token 交换。从 `trustedHosts`、转发 header 或非 loopback authority 推断这种信任，会把路由配置静默变成身份。

## Decision

`dsh-client-connection` 提供 `browserAuthentication: required | disabled`，默认值为 `required`。`disabled` 是显式部署决策：index 请求跳过启动令牌交换，打印的应用 URL 不含 token，通过既有 Host/Origin 校验的 API 请求无需浏览器 cookie 即可进入分发。Host/Origin 校验仍为强制要求，并继续对被拒请求返回 403。

该设置属于 Connection 行，而不是 Web 应用或服务器。Connection 负责 index 授权、HTTP Remote 调用、精确 Fetch 路由和 WebSocket upgrade 的认证，因此一个值会一致改变所有载体入口。随附 Web bundle 保持 `required`；profile 或后续 bundle 层必须替换 Connection 配置才能退出认证。

## Alternatives considered

**在 `trustedHosts` 非空时禁用认证。** 可信 authority 防止 DNS rebinding 与跨站请求，但不识别调用者。将两者耦合会让普通部署主机名静默授予进程权限。

**增加 `--no-auth` 应用 flag。** 单次调用 flag 在持久部署中容易遗漏，还会让 Web 应用修改由 Connection 持有的策略。Profile 配置让高影响选择与已接纳 authority 一起接受审查。

**信任转发 header。** Loopback 服务器当前没有代理身份约定或可信代理列表。接受这些 header 会让直接调用者自行声明缺失的身份。

## Consequences

禁用浏览器认证会向每个能够访问已接纳 authority 的调用者授予完整的工具型 Host API。运维人员负责外部认证、传输保密和访问撤销；此模式下 DSH 无法识别调用者或签发每浏览器会话。该退出配置不会启用非 loopback 绑定、削弱 Host/Origin 校验或改变默认值。

本决策部分取代[浏览器启动令牌认证](2026-08-24-browser-token-authentication.zh.md)中的无条件认证要求。该决策仍负责 `required` 模式、cookie 与启动令牌语义，以及被放弃的安全能力。两个模式及其理由都仍然有效，因此不归档任何 active Agent Note。
