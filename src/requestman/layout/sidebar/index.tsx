import React from 'react';
import RedirectRuleList from '../../components/RedirectRuleList';

type Props = React.ComponentProps<typeof RedirectRuleList>;

export default function Sidebar(props: Props) {
  return (
    <aside className="main-sidebar">
      <RedirectRuleList {...props} />
    </aside>
  );
}
