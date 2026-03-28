import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
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
import { Layers } from '@/components/animate-ui/icons/layers';
import { Trash2 } from '@/components/animate-ui/icons/trash-2';
import { Input } from '@/components/ui/input';
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import { t } from '../i18n';
import type { RedirectGroup, RedirectRule } from '../types';

type Props = {
  rule: RedirectRule;
  groups: RedirectGroup[];
  trigger: React.ReactElement;
  dirty?: boolean;
  isNewRule?: boolean;
  modal?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  onGroupChange: (groupId: string) => void;
  onRename: (name: string) => void;
  onDuplicate: () => void;
  onDelete: () => void;
  onSave?: () => boolean | void;
  contentProps?: Omit<React.ComponentProps<typeof DropdownMenuContent>, 'children'>;
};

export default function RuleActionsMenu({
  rule,
  groups,
  trigger,
  dirty = false,
  isNewRule = false,
  modal = true,
  open,
  onOpenChange,
  onGroupChange,
  onRename,
  onDuplicate,
  onDelete,
  onSave,
  contentProps,
}: Props) {
  const [groupDialogOpen, setGroupDialogOpen] = React.useState(false);
  const [renameDialogOpen, setRenameDialogOpen] = React.useState(false);
  const [deleteDialogOpen, setDeleteDialogOpen] = React.useState(false);
  const [renameValue, setRenameValue] = React.useState(rule.name);
  const [selectedGroupId, setSelectedGroupId] = React.useState(rule.groupId);
  const { align = 'end', ...dropdownContentProps } = contentProps ?? {};

  React.useEffect(() => {
    setRenameValue(rule.name);
  }, [rule.name]);

  React.useEffect(() => {
    setSelectedGroupId(rule.groupId);
  }, [rule.groupId]);

  const confirmRename = () => {
    const nextName = renameValue.trim();
    if (!nextName) return;
    onRename(nextName);
    setRenameDialogOpen(false);
  };

  const confirmGroupChange = () => {
    if (!selectedGroupId) return;
    onGroupChange(selectedGroupId);
    setGroupDialogOpen(false);
  };

  const duplicateRule = () => {
    if ((dirty || isNewRule) && onSave?.() === false) return;
    onDuplicate();
  };

  return (
    <>
      <DropdownMenu open={open} onOpenChange={onOpenChange} modal={modal}>
        <DropdownMenuTrigger asChild>{trigger}</DropdownMenuTrigger>
        <DropdownMenuContent align={align} {...dropdownContentProps}>
          <DropdownMenuItem onSelect={() => setRenameDialogOpen(true)}>
            <Brush size={14} animateOnHover />
            <span>{t('重命名', 'Rename')}</span>
          </DropdownMenuItem>
          <DropdownMenuItem
            onSelect={() => {
              setSelectedGroupId(rule.groupId);
              setGroupDialogOpen(true);
            }}
          >
            <Layers size={14} animateOnHover />
            <span>{t('修改规则组', 'Change group')}</span>
          </DropdownMenuItem>
          <DropdownMenuItem onSelect={duplicateRule}>
            <Copy size={14} animateOnHover />
            <span>{t('复制', 'Duplicate')}</span>
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            variant="destructive"
            onSelect={() => setDeleteDialogOpen(true)}
          >
            <Trash2 size={14} animateOnHover />
            <span>{t('删除', 'Delete')}</span>
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      <Dialog open={renameDialogOpen} onOpenChange={setRenameDialogOpen}>
        <DialogContent showCloseButton>
          <DialogHeader>
            <DialogTitle>{t('重命名规则', 'Rename rule')}</DialogTitle>
          </DialogHeader>
          <Input
            autoFocus
            value={renameValue}
            onChange={(event) => setRenameValue(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === 'Enter') confirmRename();
            }}
            placeholder={t('请输入规则名称', 'Enter rule name')}
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setRenameDialogOpen(false)}>
              {t('取消', 'Cancel')}
            </Button>
            <Button variant="default" onClick={confirmRename} disabled={!renameValue.trim()}>
              {t('确定', 'OK')}
            </Button>
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
              {groups.map((group) => (
                <SelectItem key={group.id} value={group.id}>
                  {group.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          <DialogFooter>
            <Button variant="outline" onClick={() => setGroupDialogOpen(false)}>
              {t('取消', 'Cancel')}
            </Button>
            <Button variant="default" onClick={confirmGroupChange} disabled={!selectedGroupId}>
              {t('确定', 'OK')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <AlertDialog open={deleteDialogOpen} onOpenChange={setDeleteDialogOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{t('确认删除该规则？', 'Delete this rule?')}</AlertDialogTitle>
            <AlertDialogDescription>
              {t('删除后不可恢复，当前规则配置将被移除。', 'This cannot be undone. The current rule will be removed.')}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>{t('取消', 'Cancel')}</AlertDialogCancel>
            <AlertDialogAction
              className="rule-actions-menu__delete-confirm"
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

    </>
  );
}
