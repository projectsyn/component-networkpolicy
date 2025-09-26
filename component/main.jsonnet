local com = import 'lib/commodore.libjsonnet';
local esp = import 'lib/espejote.libsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';

local inv = kap.inventory();
local params = inv.parameters.networkpolicy;

local hasEspejote = std.member(inv.applications, 'espejote');
local hasCilium = std.member(inv.applications, 'cilium');

local espNamespace = inv.parameters.espejote.namespace;
local mrName = 'espejote-networkpolicy-sync';
local rbacName = 'espejote-managedresource-networkpolicy-sync';

// RBAC for Espejote
local espejoteRBAC = [
  {
    apiVersion: 'v1',
    kind: 'ServiceAccount',
    metadata: {
      labels: {
        'app.kubernetes.io/component': 'networkpolicy',
        'app.kubernetes.io/name': mrName,
      },
      name: mrName,
      namespace: espNamespace,
    },
  },
  {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRole',
    metadata: {
      labels: {
        'app.kubernetes.io/component': 'networkpolicy',
        'app.kubernetes.io/name': rbacName,
      },
      name: rbacName,
    },
    rules: [
      {
        apiGroups: [ '' ],
        resources: [ 'namespaces' ],
        verbs: [ 'get', 'list', 'watch', 'patch' ],
      },
      {
        apiGroups: [ 'espejote.io' ],
        resources: [ 'jsonnetlibraries' ],
        resourceNames: [ mrName ],
        verbs: [ 'get', 'list', 'watch' ],
      },
      {
        apiGroups: [ 'networking.k8s.io' ],
        resources: [ 'networkpolicies' ],
        verbs: [ 'get', 'list', 'watch', 'patch', 'create', 'delete' ],
      },
      {
        apiGroups: [ 'cilium.io' ],
        resources: [ 'ciliumnetworkpolicies' ],
        verbs: [ 'get', 'list', 'watch', 'patch', 'create', 'delete' ],
      },
    ],
  },
  {
    apiVersion: 'rbac.authorization.k8s.io/v1',
    kind: 'ClusterRoleBinding',
    metadata: {
      labels: {
        'app.kubernetes.io/component': 'networkpolicy',
        'app.kubernetes.io/name': rbacName,
      },
      name: rbacName,
    },
    roleRef: {
      apiGroup: 'rbac.authorization.k8s.io',
      kind: 'ClusterRole',
      name: rbacName,
    },
    subjects: [
      {
        kind: 'ServiceAccount',
        name: mrName,
        namespace: espNamespace,
      },
    ],
  },
];

// Espejote resources
local _nameNamespaceIsolationBasic = 'namespace-isolation-basic';
local _nameNamespaceIsolationFull = 'namespace-isolation-full';
local _nameAllowFromOtherNamespaces = 'allow-from-other-namespaces';
local _nameAllowFromSameNamespace = 'allow-from-same-namespace';
local _nameAllowFromClusterNodes = 'allow-from-cluster-nodes';

local _netpolAnnotations = {
  'syn.tools/source': 'https://github.com/projectsyn/component-networkpolicy.git',
};
local _netpolLabels = {
  'app.kubernetes.io/managed-by': 'espejote',
  'app.kubernetes.io/part-of': 'syn',
  'app.kubernetes.io/component': 'networkpolicy',
};

local internalBasePolicy =
  local allowNamespaceLabels =
    local baseLabels = params.basePolicy.allowNamespaceLabels;
    params.allowNamespaceLabels + std.flattenArrays([
      if std.isArray(baseLabels[k]) then
        baseLabels[k]
      else if std.isObject(baseLabels[k]) then
        [ baseLabels[k] ]
      else if baseLabels[k] == null then
        []
      else
        error 'basePolicy.allowNamespaceLabels values must be arrays, objects, or null'
      for k in std.objectFields(baseLabels)
    ]);
  {
    policyTypes: [ 'Ingress' ],
    ingress: [ {
      from: [
        { namespaceSelector: { matchLabels: labels } }
        for labels in allowNamespaceLabels
      ],
    } ],
    podSelector: {},
  };

local ciliumInternalBasePolicy = {
  endpointSelector: {},
  ingress: if std.length(params.allowFromNodeLabels) > 0 then [
    {
      // always allow access from local node's host network, e.g. health checks.
      fromEntities: [ 'host' ],
    },
    {
      fromNodes: [
        {
          matchLabels: params.allowFromNodeLabels,
        },
      ],
    },
  ] else [
    {
      fromEntities: [
        'host',
        'remote-node',
      ],
    },
  ],
};

local basePolicies = {
  'syn-internal-set-base': internalBasePolicy,
  'cilium/syn-internal-set-base': ciliumInternalBasePolicy,
};

local jsonnetLibrary = esp.jsonnetLibrary(mrName, espNamespace) {
  spec: {
    data: {
      'config.json': std.manifestJson({
        namespaceLabels: params.labels,
        netpolAnnotations: _netpolAnnotations,
        netpolLabels: _netpolLabels,
        ignoredNamespaces: com.renderArray(params.ignoredNamespaces),
        hasCilium: hasCilium,
        policies: params.policies + basePolicies,
        policySets: {
          [set]: com.renderArray(params.policySets[set])
          for set in std.objectFields(params.policySets)
          if params.policySets[set] != null
        } + {
          base: std.objectFields(basePolicies),
        },
      }),
    },
  },
};

local managedResource = esp.managedResource(mrName, espNamespace) {
  metadata+: {
    annotations: {
      'syn.tools/description': |||
        This managed resource purges existing network policies if they are
        deployed in a namespace that is in the list of ignored namespaces.
      |||,
    },
  },
  spec: {
    context: [
      {
        name: 'namespaces',
        resource: {
          apiVersion: 'v1',
          kind: 'Namespace',
        },
      },
    ],
    triggers: [
      {
        name: 'jslib',
        watchResource: {
          apiVersion: jsonnetLibrary.apiVersion,
          kind: 'JsonnetLibrary',
          name: jsonnetLibrary.metadata.name,
          namespace: jsonnetLibrary.metadata.namespace,
        },
      },
      {
        name: 'namespace',
        watchContextResource: {
          name: 'namespaces',
        },
      },
      {
        name: 'netpol',
        watchResource: {
          apiVersion: 'networking.k8s.io/v1',
          kind: 'NetworkPolicy',
          labelSelector: {
            matchLabels: _netpolLabels,
          },
          namespace: '',
        },
      },
    ] + if hasCilium then [
      {
        name: 'ciliumnetpol',
        watchResource: {
          apiVersion: 'cilium.io/v2',
          kind: 'CiliumNetworkPolicy',
          labelSelector: {
            matchLabels: _netpolLabels,
          },
          namespace: '',
        },
      },
    ] else [],
    serviceAccountRef: {
      name: espejoteRBAC[0].metadata.name,
    },
    applyOptions: {
      force: true,
    },
    template: importstr 'espejote-templates/netpol-sync.jsonnet',
  },
};

// Define outputs below
if hasEspejote then
  {
    '01_rbac': espejoteRBAC,
    '02_library': jsonnetLibrary,
    '03_managedresource': managedResource,
  }
else
  std.trace(
    'espejote must be installed',
    {}
  )
