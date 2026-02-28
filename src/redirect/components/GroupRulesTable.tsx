import React from 'react';
import { Table } from 'antd';
import { SortableContext, verticalListSortingStrategy } from '@dnd-kit/sortable';
import type { RedirectRule } from '../types';
import SortableRow from './SortableRow';
import GroupEmptyDropZone from './GroupEmptyDropZone';

type Props = {
  groupId: string;
  groupRules: RedirectRule[];
  columns: any[];
  highlightedRuleId: string | null;
  groupEnabledMap: ReadonlyMap<string, boolean>;
  dragPreviewRules: RedirectRule[] | null;
  draggingRuleId: string | null;
};

export default function GroupRulesTable({
  groupId,
  groupRules,
  columns,
  highlightedRuleId,
  groupEnabledMap,
  dragPreviewRules,
  draggingRuleId,
}: Props) {
  return (
    <SortableContext
      items={groupRules.map((r) => r.id)}
      strategy={verticalListSortingStrategy}
    >
      <Table
        className="rules-table nested-rules-table"
        size="small"
        rowKey="id"
        showHeader={false}
        pagination={false}
        columns={columns as any}
        dataSource={groupRules}
        components={{
          body: {
            row: SortableRow,
          },
        }}
        onRow={(_record) => {
          const isProjectedDropRow =
            dragPreviewRules !== null && draggingRuleId !== null && _record.id === draggingRuleId;
          const baseBackground =
            highlightedRuleId === _record.id
              ? '#e6f4ff'
              : groupEnabledMap.get(_record.groupId) === false
                ? '#fafafa'
                : undefined;
          return {
            'data-group-id': _record.groupId,
            style: {
              background: isProjectedDropRow ? '#e5e7eb' : baseBackground,
              opacity: isProjectedDropRow ? 0.42 : 1,
              transition: 'background-color 0.2s ease, opacity 0.2s ease',
            },
          };
        }}
        locale={{ emptyText: <GroupEmptyDropZone groupId={groupId} /> }}
      />
    </SortableContext>
  );
}
