import { defineConfig } from "@coderabbitai/config"

// Approved authors for this repository, populated by the shared configuration sync.
const autoApproveAuthors = new Set(%<auto_approve_authors>s)

export default defineConfig((ctx) => ({
  inheritance: true,

  reviews: {
    request_changes_workflow: autoApproveAuthors.has(ctx.pr?.author.toLowerCase() ?? ""),
  },
}))
