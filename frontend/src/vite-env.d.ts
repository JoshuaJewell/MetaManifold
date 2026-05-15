/// <reference types="vite/client" />

declare module '*.module.css' {
  const classes: Record<string, string>
  export default classes
}

declare module 'plotly.js-dist-min' {
  const Plotly: {
    react(
      root: HTMLElement,
      data: Record<string, unknown>[],
      layout?: Record<string, unknown>,
      config?: Record<string, unknown>,
    ): Promise<void>
    relayout(root: HTMLElement, update: Record<string, unknown>): Promise<void>
    purge(root: HTMLElement): void
    newPlot(
      root: HTMLElement,
      data: Record<string, unknown>[],
      layout?: Record<string, unknown>,
      config?: Record<string, unknown>,
    ): Promise<void>
  }
  export default Plotly
  export type Data   = Record<string, unknown>
  export type Layout = Record<string, unknown>
}
