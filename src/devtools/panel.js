const groupTpl = document.querySelector('#group-template');
const ruleTpl = document.querySelector('#rule-template');
const groupsEl = document.querySelector('#groups');
const addGroupBtn = document.querySelector('#add-group-btn');

const state = {
  groups: []
};

init();

async function init() {
  await load();
  render();
  addGroupBtn.addEventListener('click', () => {
    state.groups.push(createGroup());
    renderAndSave();
  });
}

async function load() {
  const response = await sendMessage({ type: 'redirect:getConfig' });
  if (response?.ok && response.config?.groups) {
    state.groups = response.config.groups;
  }
}

function render() {
  groupsEl.innerHTML = '';

  state.groups.forEach((group, groupIndex) => {
    const groupNode = groupTpl.content.firstElementChild.cloneNode(true);
    groupNode.dataset.groupId = group.id;
    const groupName = groupNode.querySelector('.group-name');
    const groupEnabled = groupNode.querySelector('.group-enabled');
    const addRuleBtn = groupNode.querySelector('.add-rule-btn');
    const deleteGroupBtn = groupNode.querySelector('.delete-group-btn');
    const rulesEl = groupNode.querySelector('.rules');

    groupName.value = group.name;
    groupEnabled.checked = group.enabled;
    groupNode.classList.toggle('disabled', !group.enabled);

    groupName.addEventListener('input', (e) => {
      group.name = e.target.value;
      debounceSave();
    });

    groupEnabled.addEventListener('change', (e) => {
      group.enabled = e.target.checked;
      renderAndSave();
    });

    addRuleBtn.addEventListener('click', () => {
      group.rules.push(createRule());
      renderAndSave();
    });

    deleteGroupBtn.addEventListener('click', () => {
      if (window.confirm(`确定删除规则组「${group.name}」吗？`)) {
        state.groups.splice(groupIndex, 1);
        renderAndSave();
      }
    });

    bindGroupDragEvents(groupNode, groupIndex);

    group.rules.forEach((rule, ruleIndex) => {
      const ruleNode = ruleTpl.content.firstElementChild.cloneNode(true);
      ruleNode.dataset.ruleId = rule.id;
      const ruleEnabled = ruleNode.querySelector('.rule-enabled');
      const scope = ruleNode.querySelector('.scope');
      const matchType = ruleNode.querySelector('.match-type');
      const pattern = ruleNode.querySelector('.pattern');
      const redirect = ruleNode.querySelector('.redirect');
      const deleteRuleBtn = ruleNode.querySelector('.delete-rule-btn');

      ruleEnabled.checked = rule.enabled;
      scope.value = rule.scope;
      matchType.value = rule.matchType;
      pattern.value = rule.pattern;
      redirect.value = rule.redirectTo;

      ruleEnabled.disabled = !group.enabled;

      ruleEnabled.addEventListener('change', (e) => {
        rule.enabled = e.target.checked;
        save();
      });

      scope.addEventListener('change', (e) => {
        rule.scope = e.target.value;
        save();
      });

      matchType.addEventListener('change', (e) => {
        rule.matchType = e.target.value;
        save();
      });

      pattern.addEventListener('input', (e) => {
        rule.pattern = e.target.value;
        debounceSave();
      });

      redirect.addEventListener('input', (e) => {
        rule.redirectTo = e.target.value;
        debounceSave();
      });

      deleteRuleBtn.addEventListener('click', () => {
        if (window.confirm('确定删除这条规则吗？')) {
          group.rules.splice(ruleIndex, 1);
          renderAndSave();
        }
      });

      bindRuleDragEvents(ruleNode, groupIndex, ruleIndex);
      rulesEl.appendChild(ruleNode);
    });

    bindRuleDropzone(rulesEl, groupIndex);

    groupsEl.appendChild(groupNode);
  });
}

let dragGroupIndex = null;
let dragRule = null;
let saveTimer = null;

function bindGroupDragEvents(groupNode, groupIndex) {
  groupNode.addEventListener('dragstart', () => {
    dragGroupIndex = groupIndex;
  });

  groupNode.addEventListener('dragover', (e) => {
    if (dragGroupIndex === null) {
      return;
    }
    e.preventDefault();
    groupNode.classList.add('drag-over');
  });

  groupNode.addEventListener('dragleave', () => {
    groupNode.classList.remove('drag-over');
  });

  groupNode.addEventListener('drop', () => {
    groupNode.classList.remove('drag-over');
    if (dragGroupIndex === null || dragGroupIndex === groupIndex) {
      return;
    }
    const [moved] = state.groups.splice(dragGroupIndex, 1);
    state.groups.splice(groupIndex, 0, moved);
    dragGroupIndex = null;
    renderAndSave();
  });

  groupNode.addEventListener('dragend', () => {
    dragGroupIndex = null;
  });
}

function bindRuleDragEvents(ruleNode, fromGroupIndex, fromRuleIndex) {
  ruleNode.addEventListener('dragstart', () => {
    dragRule = { fromGroupIndex, fromRuleIndex };
  });

  ruleNode.addEventListener('dragover', (e) => {
    if (!dragRule) {
      return;
    }
    e.preventDefault();
    ruleNode.classList.add('drag-over');
  });

  ruleNode.addEventListener('dragleave', () => {
    ruleNode.classList.remove('drag-over');
  });

  ruleNode.addEventListener('drop', () => {
    ruleNode.classList.remove('drag-over');
    if (!dragRule) {
      return;
    }

    const { fromGroupIndex: fg, fromRuleIndex: fr } = dragRule;
    const [movedRule] = state.groups[fg].rules.splice(fr, 1);

    let insertIndex = fromRuleIndex;
    if (fg === fromGroupIndex && fr < fromRuleIndex) {
      insertIndex -= 1;
    }
    state.groups[fromGroupIndex].rules.splice(insertIndex, 0, movedRule);

    dragRule = null;
    renderAndSave();
  });

  ruleNode.addEventListener('dragend', () => {
    dragRule = null;
  });
}

function bindRuleDropzone(rulesEl, targetGroupIndex) {
  rulesEl.addEventListener('dragover', (e) => {
    if (!dragRule) {
      return;
    }
    e.preventDefault();
    rulesEl.classList.add('drag-over');
  });

  rulesEl.addEventListener('dragleave', () => {
    rulesEl.classList.remove('drag-over');
  });

  rulesEl.addEventListener('drop', () => {
    rulesEl.classList.remove('drag-over');
    if (!dragRule) {
      return;
    }

    const { fromGroupIndex, fromRuleIndex } = dragRule;
    const [movedRule] = state.groups[fromGroupIndex].rules.splice(fromRuleIndex, 1);
    state.groups[targetGroupIndex].rules.push(movedRule);

    dragRule = null;
    renderAndSave();
  });
}

function createGroup() {
  return {
    id: uid('group'),
    name: `规则组 ${state.groups.length + 1}`,
    enabled: true,
    rules: []
  };
}

function createRule() {
  return {
    id: uid('rule'),
    enabled: true,
    scope: 'url',
    matchType: 'contains',
    pattern: '',
    redirectTo: ''
  };
}

function uid(prefix) {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function renderAndSave() {
  render();
  save();
}

function debounceSave() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 300);
}

async function save() {
  await sendMessage({ type: 'redirect:saveConfig', config: state });
}

function sendMessage(payload) {
  return new Promise((resolve) => {
    chrome.runtime.sendMessage(payload, (resp) => resolve(resp));
  });
}
