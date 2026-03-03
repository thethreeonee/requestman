import React from 'react';
import { Button, Input, Space, Typography } from 'antd';
import { EditOutlined } from '@ant-design/icons';
import { RULE_TYPE_LABEL_MAP } from '../constants';
import type { RedirectRule } from '../types';

type Props = {
  rule: RedirectRule;
  editRuleName: boolean;
  setEditRuleName: React.Dispatch<React.SetStateAction<boolean>>;
  setWorkingRule: React.Dispatch<React.SetStateAction<RedirectRule | null>>;
};

export default function RuleNameHeader({ rule, editRuleName, setEditRuleName, setWorkingRule }: Props) {
  return (
    <Space align="start" style={{ marginBottom: 16 }}>
      <div>
        {editRuleName ? (
          <Input
            value={rule.name}
            onChange={(e) => setWorkingRule({ ...rule, name: e.target.value })}
            onBlur={() => setEditRuleName(false)}
            onPressEnter={() => setEditRuleName(false)}
          />
        ) : (
          <Typography.Title level={4} style={{ margin: 0 }}>{rule.name}</Typography.Title>
        )}
        <Typography.Text type="secondary" style={{ fontSize: 12 }}>
          {RULE_TYPE_LABEL_MAP[rule.type]}
        </Typography.Text>
      </div>
      <Button type="text" icon={<EditOutlined />} onClick={() => setEditRuleName(true)} />
    </Space>
  );
}
