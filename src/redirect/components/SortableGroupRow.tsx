import React from 'react';
import { useSortable } from '@dnd-kit/sortable';
import { CSS } from '@dnd-kit/utilities';
import { toGroupSortDndId } from '../dnd-utils';
import type { GroupSortDragData } from '../types';

export default function SortableGroupRow(props: React.HTMLAttributes<HTMLTableRowElement>) {
  const rowKey = props['data-row-key'];
  const groupId = String(props['data-group-id'] ?? '');
  if (typeof rowKey !== 'string' || !rowKey || !groupId) {
    return <tr {...props} />;
  }

  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({
    id: toGroupSortDndId(rowKey),
    data: { type: 'group-sort', groupId } as GroupSortDragData,
  });

  return (
    <tr
      {...props}
      ref={setNodeRef}
      style={{
        ...props.style,
        transform: CSS.Transform.toString(transform),
        transition,
      }}
      className={`${props.className ?? ''} sortable-group-row${isDragging ? ' group-row-dragging' : ''}`}
      {...attributes}
      {...listeners}
    />
  );
}
