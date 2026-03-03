import React from 'react';
import { ReloadOutlined } from '@ant-design/icons';
import { AutoComplete, Button, Form, Input, Modal, Select, Space, Tooltip } from 'antd';
import {
  COMMON_HEADER_OPTIONS,
  REQUEST_HEADER_FILTER_OPERATOR_OPTIONS,
  REQUEST_METHOD_OPTIONS,
  RESOURCE_TYPE_OPTIONS,
} from '../constants';
import type { RedirectCondition } from '../types';

type Props = {
  open: boolean;
  condition?: RedirectCondition;
  onClose: () => void;
  onConditionChange: (conditionId: string, patch: Partial<RedirectCondition>) => void;
};

export function isConditionFilterConfigured(condition: RedirectCondition) {
  return !!condition.filter.pageDomain.trim()
    || condition.filter.resourceType !== 'all'
    || condition.filter.requestMethod !== 'all'
    || (!!condition.filter.requestHeaderKey.trim() && !!condition.filter.requestHeaderValue.trim());
}

export default function ConditionFilterModal({ open, condition, onClose, onConditionChange }: Props) {
  const renderResetButton = (title: string, onClick: () => void) => (
    <Tooltip title={title}>
      <Button type="text" icon={<ReloadOutlined />} onClick={onClick} />
    </Tooltip>
  );

  return (
    <Modal open={open} title="过滤条件" onCancel={onClose} onOk={onClose}>
      {condition && (
        <Form layout="vertical">
          <Space size={8} align="end" style={{ width: '100%' }}>
            <Form.Item label="页面域名" style={{ marginBottom: 12, flex: 1 }}>
              <Input
                value={condition.filter.pageDomain}
                onChange={(e) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, pageDomain: e.target.value },
                })}
              />
            </Form.Item>
            {renderResetButton('重置页面域名', () => onConditionChange(condition.id, {
              filter: { ...condition.filter, pageDomain: '' },
            }))}
          </Space>

          <Space size={8} align="end" style={{ width: '100%' }}>
            <Form.Item label="资源类型" style={{ marginBottom: 12, flex: 1 }}>
              <Select
                value={condition.filter.resourceType}
                options={RESOURCE_TYPE_OPTIONS as never}
                onChange={(v) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, resourceType: v },
                })}
              />
            </Form.Item>
            {renderResetButton('重置资源类型', () => onConditionChange(condition.id, {
              filter: { ...condition.filter, resourceType: 'all' },
            }))}
          </Space>

          <Space size={8} align="end" style={{ width: '100%' }}>
            <Form.Item label="请求方法" style={{ marginBottom: 12, flex: 1 }}>
              <Select
                value={condition.filter.requestMethod}
                options={REQUEST_METHOD_OPTIONS as never}
                onChange={(v) => onConditionChange(condition.id, {
                  filter: { ...condition.filter, requestMethod: v },
                })}
              />
            </Form.Item>
            {renderResetButton('重置请求方法', () => onConditionChange(condition.id, {
              filter: { ...condition.filter, requestMethod: 'all' },
            }))}
          </Space>

          <Space size={8} align="end" style={{ width: '100%' }}>
            <Form.Item label="请求 Header 过滤" style={{ marginBottom: 0, flex: 1 }}>
              <Space.Compact style={{ width: '100%' }} block>
                <AutoComplete
                  options={COMMON_HEADER_OPTIONS}
                  value={condition.filter.requestHeaderKey}
                  placeholder="Header"
                  style={{ width: '30%' }}
                  onChange={(value) => onConditionChange(condition.id, {
                    filter: { ...condition.filter, requestHeaderKey: value },
                  })}
                />
                <Select
                  value={condition.filter.requestHeaderOperator}
                  options={REQUEST_HEADER_FILTER_OPERATOR_OPTIONS as never}
                  style={{ width: '22%' }}
                  onChange={(value) => onConditionChange(condition.id, {
                    filter: { ...condition.filter, requestHeaderOperator: value },
                  })}
                />
                <Input
                  value={condition.filter.requestHeaderValue}
                  placeholder="目标值"
                  style={{ width: '48%' }}
                  onChange={(e) => onConditionChange(condition.id, {
                    filter: { ...condition.filter, requestHeaderValue: e.target.value },
                  })}
                />
              </Space.Compact>
            </Form.Item>
            {renderResetButton('重置 Header 过滤', () => onConditionChange(condition.id, {
              filter: {
                ...condition.filter,
                requestHeaderKey: '',
                requestHeaderOperator: 'equals',
                requestHeaderValue: '',
              },
            }))}
          </Space>
        </Form>
      )}
    </Modal>
  );
}
