import { Button } from '@/components/animate-ui/components/buttons/button';

export function Modal({ open, title, children, onCancel, onOk }: any) {
  if (!open) return null;

  return (
    <div className="aui-modal-backdrop">
      <div className="aui-modal">
        <h3>{title}</h3>
        <div>{children}</div>
        <div className="aui-space">
          <Button variant="outline" onClick={onCancel}>Cancel</Button>
          <Button variant="default" onClick={onOk}>OK</Button>
        </div>
      </div>
    </div>
  );
}

Modal.confirm = ({ title, content, onOk }: any) => {
  if (window.confirm(`${title ?? ''}\n${content ?? ''}`)) onOk?.();
};

export function Tooltip({ title, children }: any) {
  return <span title={typeof title === 'string' ? title : ''}>{children}</span>;
}

export function Popconfirm({ title, onConfirm, children }: any) {
  return <span onClick={() => { if (window.confirm(title ?? 'Confirm?')) onConfirm?.(); }}>{children}</span>;
}
