import { Socket, type Channel } from 'phoenix';
import type { ConnectionState, EditIntent, Snapshot, Voicebank } from './types';

interface Callbacks {
  snapshot: (snapshot: Snapshot) => void;
  connection: (state: ConnectionState) => void;
  error: (message: string) => void;
}

// 唯一接线点。组件不认识 Phoenix，也不把本地预览当作工程状态。
export class ProjectClient {
  private socket?: Socket;
  private channel?: Channel;
  private stopped = false;
  private joined = false;
  private epoch = 0;
  private invalidated = false;
  private syncing?: Promise<void>;
  private removeNetworkListeners?: () => void;

  constructor(private callbacks: Callbacks) {}

  async connect() {
    const response = await fetch('/api/session');
    if (!response.ok) throw new Error('无法打开演示工程，请确认本机服务已启动。');
    const { token, project_id } = await response.json();
    if (this.stopped) return;
    this.socket = new Socket('/socket', { params: { token } });
    this.channel = this.socket.channel(`project:${project_id}`, {});
    const disconnected = () => {
      this.joined = false;
      this.epoch++;
      this.callbacks.connection('disconnected');
    };
    this.socket.onClose(disconnected);
    this.socket.onError(disconnected);
    this.channel.onError(disconnected);
    this.channel.on('project_changed', () => {
      void this.refresh().catch((error: Error) => this.callbacks.error(error.message));
    });
    this.channel.join()
      .receive('ok', ({ snapshot }: { snapshot: Snapshot }) => {
        this.joined = true;
        this.epoch++;
        this.callbacks.snapshot(snapshot);
        this.callbacks.connection('connected');
      })
      .receive('error', () => {
        disconnected();
        this.callbacks.error('工程连接失败，请重新连接。');
      })
      .receive('timeout', disconnected);
    const offline = () => { this.socket?.disconnect(); disconnected(); };
    const online = () => { if (!this.stopped) this.socket?.connect(); };
    window.addEventListener('offline', offline);
    window.addEventListener('online', online);
    this.removeNetworkListeners = () => {
      window.removeEventListener('offline', offline);
      window.removeEventListener('online', online);
    };
    this.socket.connect();
  }

  private request<T>(event: string, payload: object = {}): Promise<T> {
    if (this.stopped || !this.channel || !this.joined) {
      return Promise.reject(new Error('连接已断开，本次操作没有提交。'));
    }
    return new Promise((resolve, reject) => {
      this.channel!.push(event, payload, 10_000)
        .receive('ok', ({ data }: { data: T }) => resolve(data))
        .receive('error', ({ reason }: { reason: string }) => reject(new Error(`操作未生效：${reason}`)))
        .receive('timeout', () => reject(new Error('服务回复超时，结果尚未确认。请重新连接后核对，不要重复提交。')));
    });
  }

  // History cursor 会随 undo 变小；按请求生命周期处理，绝不比较 pin 数字大小。
  refresh(): Promise<void> {
    this.invalidated = true;
    if (this.syncing) return this.syncing;
    this.syncing = (async () => {
      while (this.invalidated && !this.stopped) {
        this.invalidated = false;
        const epoch = this.epoch;
        const snapshot = await this.request<Snapshot>('snapshot');
        if (!this.stopped && epoch === this.epoch && !this.invalidated) {
          this.callbacks.snapshot(snapshot);
        }
      }
    })().finally(() => { this.syncing = undefined; });
    return this.syncing;
  }

  voicebanks() { return this.request<Voicebank[]>('voicebanks'); }

  async edit(intent: EditIntent) {
    await this.request<number>('edit', intent);
    await this.refresh();
  }

  close() {
    this.stopped = true;
    this.epoch++;
    this.removeNetworkListeners?.();
    this.socket?.disconnect();
  }
}
