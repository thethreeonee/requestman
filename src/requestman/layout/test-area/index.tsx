import React from 'react';
import RuleTestPanel from '../../components/RuleTestPanel';

type Props = React.ComponentProps<typeof RuleTestPanel>;

export default function TestArea(props: Props) {
  return (
    <aside className="main-test-panel">
      <RuleTestPanel {...props} />
    </aside>
  );
}
