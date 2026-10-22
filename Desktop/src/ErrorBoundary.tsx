import { Component } from 'react';
import type { ErrorInfo, ReactNode } from 'react';

type Props = { children: ReactNode };
type State = { failed: boolean };

/** A broken view must not destroy recordings or leave a blank window. */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  componentDidCatch(_error: Error, info: ErrorInfo) {
    // Component names only: never log classroom text, credentials, or request bodies.
    console.error('LingoClass view failed', info.componentStack);
  }

  render() {
    if (this.state.failed) {
      return (
        <main className="recovery-screen" role="alert">
          <h1>页面遇到异常</h1>
          <p>请重新加载界面。此操作不会删除录音或课堂记录。</p>
          <button onClick={() => window.location.reload()}>重新加载</button>
        </main>
      );
    }
    return this.props.children;
  }
}
