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
  const translated = CSS.Transform.toString(transform);

  const bindRowRef = React.useCallback(
    (node: HTMLTableRowElement | null) => {
      setNodeRef(node);
      if (!node) return;

      const expandedRow = node.nextElementSibling;
      if (!(expandedRow instanceof HTMLTableRowElement)) return;
      if (!expandedRow.classList.contains('ant-table-expanded-row')) return;

      expandedRow.style.transform = translated;
      expandedRow.style.transition = transition;
      expandedRow.classList.toggle('group-expanded-row-dragging', isDragging);
    },
    [isDragging, setNodeRef, transition, translated],
  );

  React.useEffect(() => () => {
    const row = document.querySelector(`tr[data-row-key="${rowKey}"]`);
    if (!(row instanceof HTMLTableRowElement)) return;
    const expandedRow = row.nextElementSibling;
    if (!(expandedRow instanceof HTMLTableRowElement)) return;
    if (!expandedRow.classList.contains('ant-table-expanded-row')) return;
    expandedRow.style.transform = '';
    expandedRow.style.transition = '';
    expandedRow.classList.remove('group-expanded-row-dragging');
  }, [rowKey]);

  return (
    <tr
      {...props}
      ref={bindRowRef}
      style={{
        ...props.style,
        transform: translated,
        transition,
      }}
      className={`${props.className ?? ''} sortable-group-row${isDragging ? ' group-row-dragging' : ''}`}
      {...attributes}
      {...listeners}
    />
  );
}
