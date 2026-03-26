import React, { useState } from 'react';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import { Button } from '@/components/animate-ui/components/buttons/button';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from '@/components/animate-ui/components/radix/accordion';
import { Popconfirm } from '../../components';
import { t } from '../../i18n';
import { PlusOutlined } from '../../icons';
import type { RedirectCondition } from '../../types';

type Props = {
  conditions: RedirectCondition[];
  onAdd: () => string;
  onRemove: (conditionId: string) => void;
  renderContent: (condition: RedirectCondition) => React.ReactNode;
};

export default function ConditionList({ conditions, onAdd, onRemove, renderContent }: Props) {
  const [openConditions, setOpenConditions] = useState<string[]>(() => conditions.map((c) => c.id));

  const handleAdd = () => {
    const newId = onAdd();
    setOpenConditions((prev) => [...prev, newId]);
  };

  return (
    <>
      <Accordion type="multiple" value={openConditions} onValueChange={setOpenConditions} className="condition-accordion">
        {conditions.map((c) => (
          <AccordionItem key={c.id} value={c.id} className="mb-3 border rounded-lg">
            <AccordionTrigger className="px-4">
              <div style={{ display: 'flex', flex: 1, alignItems: 'center', justifyContent: 'space-between' }}>
                <span>{t('请求条件配置', 'Request conditions')}</span>
                <Popconfirm
                  title={t('确认删除该条件配置？', 'Delete this condition?')}
                  okText={t('删除', 'Delete')}
                  cancelText={t('取消', 'Cancel')}
                  okButtonProps={{ danger: true, type: 'primary' }}
                  onCancel={(e) => e?.stopPropagation()}
                  onConfirm={(e) => {
                    e?.stopPropagation();
                    onRemove(c.id);
                  }}
                >
                  <span
                    role="button"
                    tabIndex={0}
                    aria-label={t('删除条件', 'Delete condition')}
                    onMouseDown={(e) => e.stopPropagation()}
                    onPointerDown={(e) => e.stopPropagation()}
                    onClick={(e) => e.stopPropagation()}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        e.stopPropagation();
                      }
                    }}
                    style={{ color: '#ff4d4f', cursor: 'pointer', padding: '0 4px' }}
                  >
                    <Trash2 size={14} />
                  </span>
                </Popconfirm>
              </div>
            </AccordionTrigger>
            <AccordionContent className="px-4 pt-2">
              {renderContent(c)}
            </AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
      <Button
        variant="outline"
        style={{ marginTop: 12, width: '100%', height: 40, background: 'transparent' }}
        onClick={handleAdd}
      >
        <PlusOutlined />
        {t('添加新条件配置', 'Add condition')}
      </Button>
    </>
  );
}
