import React from 'react';
import { Button, Dropdown, Switch, Typography } from '../../ui';
import { Moon, Sun } from 'lucide-react';
import { Menu } from '@/components/animate-ui/icons/menu';
import { Upload } from '@/components/animate-ui/icons/upload';
import { Download } from '@/components/animate-ui/icons/download';
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
        <Typography.Text strong>REQUESTMAN</Typography.Text>
        <Switch checked={redirectEnabled} onChange={onRedirectEnabledChange} />
      </div>
      <div className="toolbar-right-tools">
        <Dropdown
          open={toolbarMenuOpen}
          onOpenChange={setToolbarMenuOpen}
          menu={{
            items: [
              { key: 'import', icon: <Download size={14} animateOnHover />, label: t('导入配置', 'Import'), onClick: importConfig },
              { key: 'export', icon: <Upload size={14} animateOnHover />, label: t('导出配置', 'Export'), onClick: exportConfig },
            ],
          }}
        >
          <Button size="sm" icon={<Menu size={16} animate={toolbarMenuOpen} />} />
        </Dropdown>
        <ThemeToggler theme={themeMode} resolvedTheme={effectiveTheme} setTheme={(theme) => setThemeMode(theme as 'light' | 'dark')}>
          {({ toggleTheme }) => {
            const next = effectiveTheme === 'light' ? 'dark' : 'light';
            return (
              <Button
                size="sm"
                onClick={() => toggleTheme(next)}
                icon={(
                  <span className="theme-toggle-icons">
                    <Sun size={16} className="theme-icon-sun" />
                    <Moon size={16} className="theme-icon-moon" />
                  </span>
                )}
              />
            );
          }}
        </ThemeToggler>
      </div>
    </div>
  );
}
