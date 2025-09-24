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

local _netpolAllowFromOtherNamespaces = {
  policyTypes: [ 'Ingress' ],
  ingress: [ {
    from: [
      { namespaceSelector: { matchLabels: labels } }
      for labels in params.allowNamespaceLabels
    ],
  } ],
  podSelector: {},
};
local _netpolAllowFromSameNamespace = {
  policyTypes: [ 'Ingress' ],
  ingress: [ {
    from: [
      { podSelector: {} },
    ],
  } ],
  podSelector: {},
};
local _netpolAllowFromClusterNodes = {
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

local jsonnetLibrary = esp.jsonnetLibrary(mrName, espNamespace) {
  spec: {
    data: {
      'config.json': std.manifestJson({
        namespaceAnnotations: params.annotations,
        namespaceLabels: params.labels,
        netpolAnnotations: _netpolAnnotations,
        netpolLabels: _netpolLabels,
        ignoredNamespaces: com.renderArray(params.ignoredNamespaces),
        hasCilium: hasCilium,
        policies: {
                    // Create default policies.
                    'allow-from-other-namespaces': _netpolAllowFromOtherNamespaces,
                    'allow-from-same-namespace': _netpolAllowFromSameNamespace,
                    'cilium/allow-from-cluster-nodes': _netpolAllowFromClusterNodes,
                  }
                  // Merge from params.policies.
                  + com.makeMergeable(params.policies),
        policySets: {
                      // Create default policy sets.
                      [_nameNamespaceIsolationBasic]: [
                        'allow-from-other-namespaces',
                        'allow-from-same-namespace',
                        'cilium/allow-from-cluster-nodes',
                      ],
                      [_nameNamespaceIsolationFull]: [
                        'allow-from-other-namespaces',
                        'cilium/allow-from-cluster-nodes',
                      ],
                    }
                    // Merge from params.policySets.
                    + com.makeMergeable(params.policySets),
        setNamespaceIsolationBasic: _nameNamespaceIsolationBasic,
        setNamespaceIsolationFull: _nameNamespaceIsolationFull,
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
      {
        name: 'ciliumpol',
        watchResource: {
          apiVersion: 'cilium.io/v2',
          kind: 'CiliumNetworkPolicy',
          labelSelector: {
            matchLabels: _netpolLabels,
          },
          namespace: '',
        },
      },
    ],
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
