export default function WorkingIndicator() {
  return (
    <div className="flex gap-1 py-2">
      <span className="w-1.5 h-1.5 rounded-full bg-[var(--color-text-muted)] animate-[pulse-dot_1.4s_infinite]" />
      <span className="w-1.5 h-1.5 rounded-full bg-[var(--color-text-muted)] animate-[pulse-dot_1.4s_infinite]" style={{ animationDelay: '0.2s' }} />
      <span className="w-1.5 h-1.5 rounded-full bg-[var(--color-text-muted)] animate-[pulse-dot_1.4s_infinite]" style={{ animationDelay: '0.4s' }} />
    </div>
  );
}
