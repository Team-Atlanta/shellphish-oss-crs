# CRS Study Notes - mdbook Setup

This directory contains study notes for the Shellphish team's CRS (Cybersecurity Reasoning System) implementation, organized as an mdbook for easy browsing and navigation.

## Prerequisites

You need to install the following tools:

### 1. Install Rust and Cargo
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

### 2. Install mdbook
```bash
cargo install mdbook
```

### 3. Install mdbook-mermaid (for diagram support)
```bash
cargo install mdbook-mermaid
mdbook-mermaid install . 
```

### 4. Install mdbook-pagetoc (for page table of contents)
```bash
cargo install mdbook-pagetoc
```

## Usage

### Build the book
Generate static HTML files:
```bash
mdbook build
```
Output will be in the `book/` directory.

### Serve the book locally
Start a local development server with live reload:
```bash
mdbook serve
```
Then open http://localhost:3000 in your browser.

### Serve on a different port
```bash
mdbook serve -p 8080
```

## Book Structure

- **book.toml** - Configuration file
- **src/** - Source markdown files
  - **SUMMARY.md** - Table of contents
  - **\*.md** - Individual study notes
- **book/** - Generated HTML output (gitignored)

## Features

- **Search functionality** - Full-text search across all notes
- **Mermaid diagrams** - Supports embedded mermaid diagrams
- **GitHub integration** - Links to source repository
- **Responsive design** - Works on mobile and desktop
- **Print support** - Can generate printer-friendly versions

## Adding Content

1. Add new markdown files to the `src/` directory
2. Update `src/SUMMARY.md` to include the new files in the navigation
3. Run `mdbook serve` to see changes live

## Mermaid Diagrams

You can include mermaid diagrams in your markdown:

\`\`\`mermaid
graph TD
    A[Start] --> B[Process]
    B --> C[End]
\`\`\`
