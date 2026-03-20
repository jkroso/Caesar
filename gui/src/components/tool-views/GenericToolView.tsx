interface Props {
  name: string;
  result: string;
}

export default function GenericToolView({ name, result }: Props) {
  return (
    <div className="border border-[var(--color-border)] rounded-xl my-2 overflow-hidden">
      <div className="bg-[var(--color-bg-muted)] px-3.5 py-1.5 text-[11px] font-semibold font-mono border-b border-[var(--color-border)] text-[var(--color-accent)]">
        {name}
      </div>
      <pre className="px-3.5 py-2.5 font-mono text-[11px] max-h-[300px] overflow-auto whitespace-pre-wrap m-0 leading-relaxed">
        {result}
      </pre>
    </div>
  );
}
