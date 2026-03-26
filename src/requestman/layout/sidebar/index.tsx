import React from 'react';
import {
  Sidebar as AppSidebar,
  SidebarProvider,
} from '@/components/animate-ui/components/radix/sidebar';
import RedirectRuleList from '../../components/RedirectRuleList';

type Props = React.ComponentProps<typeof RedirectRuleList>;

export default function Sidebar(props: Props) {
  return (
    <SidebarProvider
      defaultOpen
      className="main-sidebar-provider"
      style={{ '--sidebar-width': '352px' } as React.CSSProperties}
    >
      <AppSidebar className="main-sidebar" collapsible="none">
        <RedirectRuleList {...props} />
      </AppSidebar>
    </SidebarProvider>
  );
}
