---
title: YAAW
---

<section class="hero">
  <div>
    <p class="eyebrow">Native macOS wrapper for local CLI agents</p>
    <h1>YAAW</h1>
    <p class="hero-copy">
      Yet Another Agent Wrapper gives user-owned agent CLIs a native desktop
      workspace: projects, threads, libghostty terminal surfaces, shared local
      file indexing, Browser previews, nvim, lazygit, and configurable settings.
    </p>
    <div class="actions">
      <a class="button primary" href="{{ '/docs/user-guide/' | relative_url }}">Open the user guide</a>
      <a class="button" href="{{ '/readme.html' | relative_url }}">Read the README</a>
    </div>
  </div>
  <div class="hero-visual">
    <img src="{{ '/docs/examples/screenshots/current/main-workspace-files-terminal.png' | relative_url }}" alt="YAAW main workspace screenshot with Dracula theme">
    <div class="visual-caption">
      <span>Project and thread sidebar</span>
      <span>Agent terminal plus right-panel tools</span>
    </div>
  </div>
</section>

<section class="section">
  <div class="section-header">
    <h2>Built around your CLI, not over it.</h2>
    <p>
      YAAW is intentionally not an agent harness. It organizes the local tools
      the user already trusts while keeping authentication, model settings, and
      remote behavior in the selected CLI.
    </p>
  </div>
  <div class="feature-grid">
    <div class="feature">
      <strong>Thread-bound terminals</strong>
      <p>Each thread owns one agent CLI terminal, working directory, activity state, and resume identity.</p>
    </div>
    <div class="feature">
      <strong>Local-first storage</strong>
      <p>Projects, shared indexes, activity previews, settings, and diagnostics stay on device.</p>
    </div>
    <div class="feature">
      <strong>Browser previews</strong>
      <p>The right panel previews URLs and supported local files, including Markdown with Mermaid diagrams.</p>
    </div>
    <div class="feature">
      <strong>Terminal-backed tools</strong>
      <p>The right panel launches nvim, vim, vi, lazygit, or git diff without building custom clones.</p>
    </div>
    <div class="feature">
      <strong>Configurable surfaces</strong>
      <p>Appearance, fonts, key bindings, external-open targets, agents, tools, and ignore rules live in app-owned YAML.</p>
    </div>
  </div>
</section>

<section class="section">
  <div class="section-header">
    <h2>Documentation paths</h2>
    <p>Start with workflows, then move into requirements, design, decisions, and implementation plans.</p>
  </div>
  <div class="docs-grid">
    <a class="doc-link" href="{{ '/docs/user-guide/' | relative_url }}">
      <strong>User Guide</strong>
      <span>Project creation, thread selection, right-panel tools, settings, and daily workflow.</span>
    </a>
    <a class="doc-link" href="{{ '/docs/requirements/technical-requirements.html' | relative_url }}">
      <strong>Technical Requirements</strong>
      <span>Native macOS scope, terminal behavior, persistence, indexing, and tool integration.</span>
    </a>
    <a class="doc-link" href="{{ '/docs/requirements/non-functional-requirements.html' | relative_url }}">
      <strong>Non-Functional Requirements</strong>
      <span>Performance, privacy, reliability, accessibility, and maintainability constraints.</span>
    </a>
    <a class="doc-link" href="{{ '/docs/design/' | relative_url }}">
      <strong>Design</strong>
      <span>Application structure, theme behavior, layout model, and implementation notes.</span>
    </a>
    <a class="doc-link" href="{{ '/docs/plans/implementation-order.html' | relative_url }}">
      <strong>Implementation Plans</strong>
      <span>Sequenced work across state, persistence, terminal abstraction, panels, and hardening.</span>
    </a>
    <a class="doc-link" href="{{ '/docs/decisions/' | relative_url }}">
      <strong>Decisions</strong>
      <span>Architecture records for scrollback, project metadata, and global thread behavior.</span>
    </a>
  </div>
</section>

<section class="section">
  <div class="section-header">
    <h2>Interface reference</h2>
    <p>Current visual examples from the repository, surfaced directly instead of hidden behind text links.</p>
  </div>
  <div class="gallery">
    <figure>
      <a href="{{ '/docs/examples/screenshots/current/main-workspace-files-terminal.png' | relative_url }}">
        <img src="{{ '/docs/examples/screenshots/current/main-workspace-files-terminal.png' | relative_url }}" alt="YAAW file browser right panel">
      </a>
      <figcaption>Current workspace</figcaption>
    </figure>
    <figure>
      <a href="{{ '/docs/examples/screenshots/right-panel-lazygit-mode-dracula.png' | relative_url }}">
        <img src="{{ '/docs/examples/screenshots/right-panel-lazygit-mode-dracula.png' | relative_url }}" alt="YAAW lazygit right panel">
      </a>
      <figcaption>lazygit mode</figcaption>
    </figure>
  </div>
</section>
