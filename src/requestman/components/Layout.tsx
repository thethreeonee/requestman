function SpaceBase({ children, direction, size, style, align }: any) {
  return <div className={`aui-space ${direction === 'vertical' ? 'vertical' : ''}`} style={{ gap: size ?? 8, alignItems: align, ...style }}>{children}</div>;
}

SpaceBase.Compact = function Compact({ children, style }: any) {
  return <div className="aui-compact" style={style}>{children}</div>;
};

SpaceBase.Addon = function Addon({ children, style }: any) {
  return <span className="aui-addon" style={style}>{children}</span>;
};

export const Space = SpaceBase as any;
