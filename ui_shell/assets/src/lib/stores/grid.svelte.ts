import { DEFAULT_QUANTUM } from "../grid";

// Grid 设置（enable + 最小单位），仿 viewport.svelte.ts 的类模式；
// 每个 PianoRoll 实例持有一份，由外层控件事先绑定。
export class GridSettings {
  enabled = $state(true);
  quantum = $state(DEFAULT_QUANTUM);
}
