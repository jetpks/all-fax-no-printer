// @types/react-syntax-highlighter ships types for the package entry but not the
// deep per-language ESM paths we import for the PrismLight build. Declare them.
declare module 'react-syntax-highlighter/dist/esm/languages/prism/*' {
  const language: unknown
  export default language
}

declare module 'react-syntax-highlighter/dist/esm/prism-light' {
  import type { ComponentType } from 'react'
  import type { SyntaxHighlighterProps } from 'react-syntax-highlighter'
  const SyntaxHighlighter: ComponentType<SyntaxHighlighterProps> & {
    registerLanguage: (name: string, language: unknown) => void
  }
  export default SyntaxHighlighter
}

// @types declares this barrel but omits nightOwl (it only ships a handful of
// prism theme names). Merge the missing member in as a named export — matches
// the @types declaration style so the two ambient blocks merge cleanly
// (TS7 rejects the previous `export =` Record here for named imports).
declare module 'react-syntax-highlighter/dist/esm/styles/prism' {
  export const nightOwl: Record<string, React.CSSProperties>
}
