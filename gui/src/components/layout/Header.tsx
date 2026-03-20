interface Props {
  title: string;
  model?: string;
  sidebarOpen: boolean;
}

export default function Header({ title, model, sidebarOpen }: Props) {
  return (
    <header className="relative border-b border-[var(--color-border)] bg-[var(--color-bg)]">
      {/* Drag region fills the header */}
      <div className="absolute inset-0" data-tauri-drag-region="true" />
      <div
        className="relative px-4 flex items-center justify-between h-[38px]"
        style={!sidebarOpen ? { paddingLeft: "56px" } : undefined}
      >
        <span className="font-medium text-[13px] tracking-[-0.01em] text-[var(--color-text-secondary)]">{title}</span>
        {model && <span className="text-[11px] text-[var(--color-text-muted)]">{model}</span>}
      </div>
    </header>
  );
}
