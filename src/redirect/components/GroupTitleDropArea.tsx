import React from 'react';
import { Switch } from 'antd';
import { useDroppable } from '@dnd-kit/core';
import type { GroupDropData, RedirectGroup } from '../types';

type Props = {
  group: RedirectGroup;
  activeCount: number;
  totalCount: number;
  disabled?: boolean;
  onToggle: (groupId: string, enabled: boolean) => void;
};

export default function GroupTitleDropArea({
  group,
  activeCount,
  totalCount,
  disabled = false,
  onToggle,
}: Props) {
  const { setNodeRef } = useDroppable({
    id: `group-row-drop:${group.id}`,
    data: { type: 'group', groupId: group.id } as GroupDropData,
  });

  return (
    <div ref={setNodeRef} className="group-title-drop-area">
      <div className="group-title-drop-area-inner">
        <Switch
          size="small"
          checked={group.enabled}
          disabled={disabled}
          onChange={(checked) => onToggle(group.id, checked)}
        />
        <span style={{ display: 'inline-flex', alignItems: 'center', lineHeight: '20px', fontWeight: 600 }}>
          {group.name}
        </span>
        <span style={{ display: 'inline-flex', alignItems: 'center', lineHeight: '20px', color: '#6b7280' }}>
          ({activeCount}/{totalCount})
        </span>
      </div>
    </div>
  );
}
