# Equinox UI：单音符与音高干预原型

Svelte 5 + TypeScript + SVG 工作区，Phoenix Channel 把组件意图交给 Neumu。
当前是可运行的单音符纵向原型：歌词/音高修改、横向拖动、撤销/重做、
声库选择、音高点列干预、检查与修复都接入真实 Neumu facade / Coconut History，
并支持刷新重读和断线重连。

默认演示工程使用 `Neume.Engine.MockPipeline`，声库 A/B 是明确标注的
演示条目，不读取外部声库、不合成音频。工程只保留在服务进程中；重启
会重新创建。此阶段没有工程保存 UI、渲染/播放、Bezier 或音素时长编辑。

## 启动

在仓库根目录获取 Elixir 依赖：

```powershell
mix deps.get
```

构建浏览器资源：

```powershell
cd apps/equinox_web/assets
npm ci
npm run build
```

回到仓库根目录，在独立终端运行：

```powershell
$env:EQUINOX_WEB_SERVER = '1'
mix run --no-halt
```

打开 <http://127.0.0.1:4000>。组件状态样例页为
<http://127.0.0.1:4000/?components>，不访问后端。
按 Ctrl+C 终止服务会结束演示会话。普通 `mix test` 不设置上述变量，
不会监听端口或创建演示工程。

开发时可在 assets 目录运行 `npm run dev`，访问
<http://127.0.0.1:5173>；Vite 把 `/api` 与 `/socket` 转发到上述后端。

## 本阶段边界

- 工作区只编辑第一轨的一枚音符；横向拖动吸附 120 tick，移动与音高修改
  是独立手势，每次只调用一条 facade 编辑命令。拖动中只是本地预览，
  松手提交，Esc/窗口失焦/版本变化取消。方向键可横向微移。
- 卷帘展示 MIDI 56–72，音高输入限制在相同范围。480 tick/拍，标尺暂按
  固定 4/4、120 BPM 展示。多音符排序、伸缩、插删和变速交互留给下一批。
- `src/lib/types.ts` 定义组件数据与意图；`ProjectClient` 独占 socket 和
  工程快照查询。组件不得直接调用后端、复制 History 或判定干预身份。
- `project_changed` 只表示镜像失效，串行重查快照；查询回复使用连接代际
  过滤，不能用 history_pin 数字大小判断新旧（undo 会使其减小）。
- 修改失败显示错误，音符表单草稿保留；提交结果未知时不自动重发，先
  重新连接并核对权威状态。权威版本变化会重新初始化音符表单草稿。
- 声库选择是本地草稿，只有“应用声库”才提交。列表数据与当前绑定分离，
  绑定成功及撤销后的显示只取权威快照。
- 撤销/重做沿用现有 History 的全局 seq 遍历，不按树节点 parent 回退；
  在旧版本上产生新分支后，撤销可能进入另一分支。UI 不另外实现历史语义。
- 音高点列在卷帘上双击加点、拖动调整，或在表单中填写相对偏移与绝对
  MIDI；“应用音高调校”才提交。新建走预检令牌 + mount，修改已有调校
  走 replace，避免重复叠加。版本变化丢弃旧草稿，Esc 取消本次点拖动。
- 检查在 Channel 外异步执行，每连接最多一个；返回结果须匹配发起时的
  版本和连接生命周期。编辑、撤销、事件失效和断线都清除旧检查结果。
  标记直接落在卷帘上，可尝试沿用、重新编辑或移除；repatch 降级保留
  原件并明确提示。mock 共用音高范围校验，但不验证声学模型质量。
- v2 谱面音高干预改词、改音高、横移后仍存活，不人为制造身份冲突。
  兼容格式或多条同音符 pin 不支持点列编辑，保留显式移除入口。
- 新 mount 有服务端原子 stale-write 校验；replace 的现有 facade 没有
  history 令牌参数，浏览器预检只缩小窗口，不能保证跨客户端并发替换安全。
  本原型按单人操作验收。
- 服务只绑定 loopback；连接令牌限定单个工程，WebSocket 校验本机来源。
  这是本机开发宿主，不包含远程账户、权限或发布部署配置。

## 验证

仓库根目录：

```powershell
mix test apps/equinox_web/test
mix compile --force --warnings-as-errors
mix format --check-formatted
```

assets 目录：

```powershell
npm run check
npm run build
npx playwright install chromium
npm test
```

Windows 下 Mix 可能复制而非链接 `priv`：服务运行期间重新执行
`npm run build` 后，需在仓库根目录执行 `mix compile` 同步静态文件；
日常界面开发建议使用 Vite 地址。

浏览器测试需要先启动上述演示服务，测试会编辑该临时演示工程，不应与
人工验收同时运行。覆盖真实提交、撤销/重做、刷新、拖动取消、声库状态、
跨页面同步与断线恢复，以及音高草稿、越界降级、重写/移除、过期检查回复。
测试截图/trace 和构建输出均不入版本库。

`VoicebankSelector.svelte`、`PitchControls.svelte` 初稿由 Kimi Code 在后台
按固定 props/意图契约独立完成；
主代理负责集成、可访问性修正及真实工程行为验证。

2026-09-17 path 2 验证：9 项 Channel 测试、7 项浏览器场景通过；前端
check/build、严格编译、Dialyzer（0 错误）通过。完整回归结果见根 AGENTS。
上个里程碑后用户运行 `mix test --only integration`，适配器集成测试
8 项通过；本批未重跑真声库，OpenVINO 测试未运行。

手工验收：编辑音高调校 → 应用 → 检查；将第二个控制点偏移设为 600
（起手音符长度 480），可体验越界标记、沿用降级、改回 360 后通过检查。
