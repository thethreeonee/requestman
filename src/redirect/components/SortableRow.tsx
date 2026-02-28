import React from 'react';
import { useSortable } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import type { RuleDragData } from '../types';

export default function SortableRow(props: React.HTMLAttributes<HTMLTableRowElement>) {
  const rowKey = props['data-row-key'];
  if (typeof rowKey !== 'string' || !rowKey) {
    return <tr {...props} />;
  }
  const groupId = String(props['data-group-id'] ?? '');
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: rowKey,
    data: { type: 'rule', groupId } as RuleDragData,
  });

  const style = {
    ...props.style,
    transform: CSS.Transform.toString(transform),
    transition,
  };
  const className = `${props.className ?? ''} sortable-row${isDragging ? ' row-dragging' : ''}`;

  return (
    <tr
      {...props}
      ref={setNodeRef}
      style={style}
      className={className}
      {...attributes}
      {...listeners}
    />
  );
}
