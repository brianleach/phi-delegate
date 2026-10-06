export type PhiDelegateReview = {
  name: string
  status: 'running' | 'ready' | 'merged' | 'rejected' | 'failed'
  output: string
}

declare module 'claude-code' {
  interface PluginState {
    'phi-delegate': {
      flagged: number
      reviews: PhiDelegateReview[]
    }
  }
}
