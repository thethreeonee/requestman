import React from 'react';
import { Button } from '@/components/animate-ui/components/buttons/button';
import { Switch } from '@/components/animate-ui/components/radix/switch';
import { Moon, Sun } from 'lucide-react';
import { Menu } from '@/components/animate-ui/icons/menu';
import { Upload } from '@/components/animate-ui/icons/upload';
import { Download } from '@/components/animate-ui/icons/download';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from '@/components/animate-ui/components/radix/dropdown-menu';
import { ThemeToggler } from '@/components/animate-ui/primitives/effects/theme-toggler';
import { t } from '../../i18n';

type Props = {
  redirectEnabled: boolean;
  onRedirectEnabledChange: (value: boolean) => void;
  toolbarMenuOpen: boolean;
  setToolbarMenuOpen: (open: boolean) => void;
  importConfig: () => void;
  exportConfig: () => void;
  themeMode: 'light' | 'dark';
  effectiveTheme: 'light' | 'dark';
  setThemeMode: (theme: 'light' | 'dark') => void;
};

export default function TopBar({
  redirectEnabled,
  onRedirectEnabledChange,
  toolbarMenuOpen,
  setToolbarMenuOpen,
  importConfig,
  exportConfig,
  themeMode,
  effectiveTheme,
  setThemeMode,
}: Props) {
  return (
    <div className="global-toolbar">
      <div className="toolbar-left-tools">
        <img className="toolbar-logo" src="/assets/icon-source.png" alt="logo" style={{ width: 24, height: 24 }} />
        <strong>REQUESTMAN</strong>
        <Switch checked={redirectEnabled} onCheckedChange={onRedirectEnabledChange} />
      </div>
      <div className="toolbar-right-tools">
        <DropdownMenu open={toolbarMenuOpen} onOpenChange={setToolbarMenuOpen}>
          <DropdownMenuTrigger asChild>
            <span>
              <Button variant="outline" size="sm"><Menu size={16} animate={toolbarMenuOpen} /></Button>
            </span>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" sideOffset={6}>
            <DropdownMenuItem onSelect={importConfig}>
              <Download size={14} animateOnHover />
              {t('导入配置', 'Import')}
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={exportConfig}>
              <Upload size={14} animateOnHover />
              {t('导出配置', 'Export')}
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <ThemeToggler theme={themeMode} resolvedTheme={effectiveTheme} setTheme={(theme) => setThemeMode(theme as 'light' | 'dark')}>
          {({ toggleTheme }) => {
            const next = effectiveTheme === 'light' ? 'dark' : 'light';
            return (
              <Button
                variant="outline"
                size="sm"
                onClick={() => toggleTheme(next)}
              >
                <span className="theme-toggle-icons">
                  <Sun size={16} className="theme-icon-sun" />
                  <Moon size={16} className="theme-icon-moon" />
                </span>
              </Button>
            );
          }}
        </ThemeToggler>
      </div>
    </div>
  );
}
