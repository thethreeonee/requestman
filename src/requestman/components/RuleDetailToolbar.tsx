import React, { useEffect, useState } from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { Input } from '@/components/ui/input';
import { Switch } from '@/components/animate-ui/components/radix/switch';
import { AnimateIcon } from '@/components/animate-ui/icons/icon';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from '@/components/animate-ui/components/radix/alert-dialog';
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/components/radix/dialog';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/animate-ui/components/radix/dropdown-menu';
import { Brush } from '@/components/animate-ui/icons/brush';
import { Copy } from '@/components/animate-ui/icons/copy';
import { Ellipsis } from '@/components/animate-ui/icons/ellipsis';
import { Layers } from '@/components/animate-ui/icons/layers';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import type { RedirectGroup, RedirectRule } from '../types';
import { t } from '../i18n';
import { renderRuleTypeIcon } from '../rule-type-meta';

type Props = {
  rule: RedirectRule;
  groups: RedirectGroup[];
  groupId: string;
  isNewRule: boolean;
  dirty: boolean;
  onGroupChange: (groupId: string) => void;
  onEnabledChange: (enabled: boolean) => void;
  onTest: () => void;
  onSave: () => boolean | void;
  onRename: (name: string) => void;
  onDuplicate: () => void;
  onDelete: () => void;
};

export default function RuleDetailToolbar({
  rule,
  groups,
  groupId,
  isNewRule,
  dirty,
  onGroupChange,
  onEnabledChange,
  onTest,
  onSave,
  onRename,
  onDuplicate,
  onDelete,
}: Props) {
  const [actionsOpen, setActionsOpen] = useState(false);
  const [groupDialogOpen, setGroupDialogOpen] = useState(false);
  const [renameDialogOpen, setRenameDialogOpen] = useState(false);
  const [deleteDialogOpen, setDeleteDialogOpen] = useState(false);
  const [renameValue, setRenameValue] = useState(rule.name);
  const [selectedGroupId, setSelectedGroupId] = useState(groupId);

  useEffect(() => {
    setRenameValue(rule.name);
  }, [rule.name]);

  useEffect(() => {
    setSelectedGroupId(groupId);
  }, [groupId]);

  const confirmRename = () => {
    const nextName = renameValue.trim();
    if (!nextName) return;
    onRename(nextName);
    setRenameDialogOpen(false);
  };

  const duplicateRule = () => {
    if ((dirty || isNewRule) && onSave() === false) return;
    onDuplicate();
  };

  const confirmGroupChange = () => {
    if (!selectedGroupId) return;
    onGroupChange(selectedGroupId);
    setGroupDialogOpen(false);
  };

  return <>
    <div className="detail-header">
      <div className="detail-header__title">
        <span className="detail-header__title-icon" aria-hidden="true">{renderRuleTypeIcon(rule.type)}</span>
        <span className="detail-header__title-text">{rule.name || t('未命名规则', 'Untitled rule')}</span>
        <Switch
          checked={rule.enabled}
          onCheckedChange={onEnabledChange}
          aria-label={rule.enabled ? t('禁用规则', 'Disable rule') : t('启用规则', 'Enable rule')}
          className="detail-header__enabled-switch"
        />
      </div>
      <div className="aui-space">
        <DropdownMenu open={actionsOpen} onOpenChange={setActionsOpen}>
          <DropdownMenuTrigger asChild>
            <span>
              <Button
                variant="outline"
                size="icon"
                className="detail-header__menu-btn"
                aria-label={t('规则操作', 'Rule actions')}
              >
                <Ellipsis size={16} />
              </Button>
            </span>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end">
            <AnimateIcon animateOnHover asChild>
              <DropdownMenuItem
                onSelect={() => {
                  setRenameDialogOpen(true);
                }}
              >
                <Brush size={14} />
                <span>{t('重命名', 'Rename')}</span>
              </DropdownMenuItem>
            </AnimateIcon>
            <AnimateIcon animateOnHover asChild>
              <DropdownMenuItem
                onSelect={() => {
                  setSelectedGroupId(groupId);
                  setGroupDialogOpen(true);
                }}
              >
                <Layers size={14} />
                <span>{t('修改规则组', 'Change group')}</span>
              </DropdownMenuItem>
            </AnimateIcon>
            <AnimateIcon animateOnHover asChild>
              <DropdownMenuItem onSelect={duplicateRule}>
                <Copy size={14} />
                <span>{t('复制', 'Duplicate')}</span>
              </DropdownMenuItem>
            </AnimateIcon>
            <DropdownMenuSeparator />
            <AnimateIcon animateOnHover asChild>
              <DropdownMenuItem
                variant="destructive"
                onSelect={() => {
                  setDeleteDialogOpen(true);
                }}
              >
                <Trash2 size={14} />
                <span>{t('删除', 'Delete')}</span>
              </DropdownMenuItem>
            </AnimateIcon>
          </DropdownMenuContent>
        </DropdownMenu>
        <Button variant="outline" onClick={onTest}>{t('测试', 'Test')}</Button>
        <Button
          variant="default"
          disabled={!dirty}
          onClick={() => {
            onSave();
          }}
        >
          <span>{t('保存规则', 'Save rule')}</span>
        </Button>
      </div>
    </div>
    <Dialog open={renameDialogOpen} onOpenChange={setRenameDialogOpen}>
      <DialogContent showCloseButton>
        <DialogHeader>
          <DialogTitle>{t('重命名规则', 'Rename rule')}</DialogTitle>
        </DialogHeader>
        <Input
          autoFocus
          value={renameValue}
          onChange={(e) => setRenameValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') confirmRename();
          }}
          placeholder={t('请输入规则名称', 'Enter rule name')}
        />
        <DialogFooter>
          <Button variant="outline" onClick={() => setRenameDialogOpen(false)}>{t('取消', 'Cancel')}</Button>
          <Button variant="default" onClick={confirmRename} disabled={!renameValue.trim()}>{t('确定', 'OK')}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
    <Dialog open={groupDialogOpen} onOpenChange={setGroupDialogOpen}>
      <DialogContent showCloseButton className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>{t('修改规则组', 'Change group')}</DialogTitle>
        </DialogHeader>
        <Select value={selectedGroupId || undefined} onValueChange={setSelectedGroupId}>
          <SelectTrigger className="w-full">
            <SelectValue placeholder={t('规则组：请选择', 'Select group')} />
          </SelectTrigger>
          <SelectContent>
            {groups.map((g) => (
              <SelectItem key={g.id} value={g.id}>{g.name}</SelectItem>
            ))}
          </SelectContent>
        </Select>
        <DialogFooter>
          <Button variant="outline" onClick={() => setGroupDialogOpen(false)}>{t('取消', 'Cancel')}</Button>
          <Button variant="default" onClick={confirmGroupChange} disabled={!selectedGroupId}>{t('确定', 'OK')}</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
    <AlertDialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{t('确认删除该规则？', 'Delete this rule?')}</AlertDialogTitle>
          <AlertDialogDescription>{t('删除后不可恢复，当前规则配置将被移除。', 'This cannot be undone. The current rule will be removed.')}</AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>{t('取消', 'Cancel')}</AlertDialogCancel>
          <AlertDialogAction
            onClick={() => {
              onDelete();
              setDeleteDialogOpen(false);
            }}
          >
            {t('删除', 'Delete')}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  </>;
}
