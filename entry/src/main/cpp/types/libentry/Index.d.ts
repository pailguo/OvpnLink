export interface StatusInfo {
  state: string;
  duration: number;
  bytesIn: number;
  bytesOut: number;
}

export interface AuthInfo {
  type: string;
  prompt: string;
}

export const add: (a: number, b: number) => number;
export const start: (profileJson: string) => number;
export const stop: () => number;
export const reconnect: () => number;
export const isRunning: () => number;
export const setTunFd: (fd: number) => number;
export const getIpv6Config: () => string;
export const getIpv6Routes: () => string;
export const setCredentials: (json: string) => number;
export const sendAuth: (username: string, password: string) => number;
export const getVersion: () => string;
export const onStatus: (cb: (s: string) => void) => void;
export const onLog: (cb: (line: string) => void) => void;
export const onTunRequest: (cb: (info: string) => void) => void;
export const onProtectFd: (cb: (fdStr: string) => void) => void;
export const onAuthRequest: (cb: (info: string) => void) => void;
export const onByteCount: (cb: (data: string) => void) => void;
export const onState: (cb: (data: string) => void) => void;
