# LingoClass 工程规范

适用范围：共享桌面版 `Desktop` 和 `Tools/transcription-mvp`。历史实验目录和旧 Swift 客户端不作为当前发布入口。规范根据项目规模采纳，不代表通过 Google 认证。

## 参考依据

- [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html)：清晰命名、导入、异常边界、日志和并发代码约束。
- [Google TypeScript Style Guide](https://google.github.io/styleguide/tsguide.html)：明确类型、避免 `any`、可读命名。
- [Google AIP-193](https://google.aip.dev/193)：错误应有稳定的机器标识及适合用户的说明。本项目采用简化的本地 HTTP 契约，未实现完整 Google RPC 格式。
- [Google SRE: Handling Overload](https://sre.google/sre-book/handling-overload/)：限制排队、控制重试和超时，避免故障期间放大负载。

## 命名和书写

产品名统一为 **LingoClass**，前端包为 `@lingoclass/desktop`。Python 模块/函数/变量使用 snake_case，类用 PascalCase，常量用 UPPER_SNAKE_CASE；React 组件和类型用 PascalCase，前端函数/变量用 camelCase。

历史目录 `Tools/transcription-mvp`、持久化字段及 HTTP 字段保持兼容，禁止为了外观统一直接改掉已保存数据的字段。新模块使用功能名，例如 `app_errors`、`json_storage`、`apiClient`。旧 `Lab`/`Handler` 只作为兼容别名，主体类为 `TranscriptionSession`/`DesktopRequestHandler`。

Python 使用 Ruff 格式化与选定规则；前端使用 Prettier、Oxlint 和 TypeScript strict。工具配置是自动检查的依据，不声称逐条照搬 Google 的工具和行宽。注释解释约束及原因；禁止吞掉异常后假装成功，禁止在界面直接展示内部堆栈。

## 错误和即时反馈

HTTP 失败返回 `error`、`code`、`retryable`、`request_id`，响应头包含 `X-Request-ID`。参数错误 400、会话失效 403、不存在 404、状态冲突 409、过大请求 413、服务不可用 503、超时 504、磁盘满 507、未预期错误 500。

用户触发操作立即进入忙碌状态，重复点击不重复提交；失败消息持续显示并带问题编号。保存设置失败要回滚界面。后台连接失败要显示状态，保留已有字幕，重连采用有上限的退避。写操作超时可能仍在执行，禁止自动重试；先查询状态。页面渲染崩溃显示恢复入口。

## 数据和任务

关键 JSON 先完整写临时文件，再在同一文件系统原子替换。课程库维护上一份有效备份；损坏内容保留并报错，不静默清空。每个文件的原子替换不等于跨文件事务。备份需要额外磁盘空间。

空课堂在创建总结任务前拦截。同一课堂的总结、精修各自去重；应用退出后的旧处理中状态显示为可重试的中断。精修只由用户发起，提供进度和取消，成功部分及时保存。取消不保证撤回供应商已经接收的请求，其结束时间受请求超时限制。

工作队列必须有容量或背压策略；字幕应优先于说话人辅助分析。跨课堂异步结果通过 generation 隔离，缓存必须包含课程术语且有容量限制。后台线程的退出等待必须有上限。

## 验证和交付

本地后端：`python -m ruff check Tools/transcription-mvp`、`python -m ruff format --check Tools/transcription-mvp`、`python -m unittest discover -s Tools/transcription-mvp -p "test_*.py" -q`。

前端在 `Desktop` 执行 `npm run format:check`、`npm run lint`、`npm test`、`npm run build`。开发环境为 Python 3.12、Node 24。提交后的自动检查定义在 `.github/workflows/quality.yml`。

自动测试通过不代表真实麦克风、长课堂、安装包或真实 Mac 已验收。发布记录必须分别列出源码检查、故障注入、UI、设备和安装验证结果。
