import React, { useState } from 'react';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
import { Button } from '@/components/animate-ui/components/buttons/button';
import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from '@/components/animate-ui/components/radix/accordion';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/animate-ui/components/radix/alert-dialog';
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
                <AlertDialog>
                  <AlertDialogTrigger asChild>
                    <AnimateIcon animateOnHover asChild>
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
                    </AnimateIcon>
                  </AlertDialogTrigger>
                  <AlertDialogContent>
                    <AlertDialogHeader>
                      <AlertDialogTitle>{t('确认删除该条件配置？', 'Delete this condition?')}</AlertDialogTitle>
                    </AlertDialogHeader>
                    <AlertDialogFooter>
                      <AlertDialogCancel>{t('取消', 'Cancel')}</AlertDialogCancel>
                      <AlertDialogAction onClick={() => onRemove(c.id)}>{t('删除', 'Delete')}</AlertDialogAction>
                    </AlertDialogFooter>
                  </AlertDialogContent>
                </AlertDialog>
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
        className="w-full mt-3"
        hoverScale={1.01}
        onClick={handleAdd}
      >
        <PlusOutlined />
        {t('添加新条件配置', 'Add condition')}
      </Button>
    </>
  );
}
