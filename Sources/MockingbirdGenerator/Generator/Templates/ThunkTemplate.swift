import Foundation

class ThunkTemplate: Template {
  let mockableType: MockableType
  let invocation: String
  let shortSignature: String?
  let longSignature: String
  let returnType: String
  let isBridged: Bool
  let isAsync: Bool
  let isThrowing: Bool
  let isStatic: Bool
  let isOptional: Bool
  let callMember: (_ scope: Scope) -> String
  let invocationArguments: [(argumentLabel: String?, parameterName: String)]
  
  enum Scope: CustomStringConvertible {
    case `super`
    case object
    var description: String {
      switch self {
      case .super: return "super"
      case .object: return "mkbObject"
      }
    }
  }
  
  init(mockableType: MockableType,
       invocation: String,
       shortSignature: String?,
       longSignature: String,
       returnType: String,
       isBridged: Bool,
       isAsync: Bool,
       isThrowing: Bool,
       isStatic: Bool,
       isOptional: Bool,
       callMember: @escaping (_ scope: Scope) -> String,
       invocationArguments: [(argumentLabel: String?, parameterName: String)]) {
    self.mockableType = mockableType
    self.invocation = invocation
    self.shortSignature = shortSignature
    self.longSignature = longSignature
    self.returnType = returnType
    self.isBridged = isBridged
    self.isAsync = isAsync
    self.isThrowing = isThrowing
    self.isStatic = isStatic
    self.isOptional = isOptional
    self.callMember = callMember
    self.invocationArguments = invocationArguments
  }
  
  func render() -> String {
    let unlabledArguments = invocationArguments.map({ $0.parameterName })
    let callDefault = IfStatementTemplate(
      condition: "let mkbImpl = mkbImpl as? \(longSignature)",
      body: """
      return \(FunctionCallTemplate(name: "mkbImpl",
                                    unlabeledArguments: unlabledArguments,
                                    isAsync: isAsync,
                                    isThrowing: isThrowing))
      """).render()
    let callConvenience: String = {
      guard let shortSignature = shortSignature else { return "" }
      return IfStatementTemplate(
        condition: "let mkbImpl = mkbImpl as? \(shortSignature)",
        body: """
        return \(FunctionCallTemplate(name: "mkbImpl", isAsync: isAsync, isThrowing: isThrowing))
        """).render()
    }()
    
    let callBridgedDefault: String = {
      guard isBridged else { return "" }
      let bridgedSignature = """
      (\(String(list: Array(repeating: "Any?", count: unlabledArguments.count)))) -> Any
      """
      return IfStatementTemplate(
        condition: "let mkbImpl = mkbImpl as? \(bridgedSignature)",
        body: """
        return \(FunctionCallTemplate(
                  name: "Mockingbird.dynamicCast",
                  unlabeledArguments: [
                    FunctionCallTemplate(
                      name: "mkbImpl",
                      unlabeledArguments: unlabledArguments.map({ $0 + " as Any?" }),
                      isAsync: isAsync,
                      isThrowing: isThrowing).render()
                  ])) as \(returnType)
        """).render()
    }()
    let callBridgedConvenience: String = {
      guard isBridged, !unlabledArguments.isEmpty else { return "" }
      return IfStatementTemplate(
        condition: "let mkbImpl = mkbImpl as? () -> Any",
        body: """
        return \(FunctionCallTemplate(
                  name: "Mockingbird.dynamicCast",
                  unlabeledArguments: [
                    FunctionCallTemplate(name: "mkbImpl",
                                         isAsync: isAsync,
                                         isThrowing: isThrowing).render()
                  ])) as \(returnType)
        """).render()
    }()
    let callProxyObject: String = {
      let objectInvocation = callMember(.object)
      guard !objectInvocation.isEmpty else { return "" }
      return "let mkbValue: \(returnType) = \(objectInvocation)"
    }()
    
    let supertype = isStatic ? "MockingbirdSupertype.Type" : "MockingbirdSupertype"
    let didInvoke = FunctionCallTemplate(name: "self.mockingbirdContext.mocking.didInvoke",
                                         unlabeledArguments: [invocation],
                                         isAsync: isAsync,
                                         isThrowing: isThrowing)
    
    let isSubclass = mockableType.kind != .class
    
    // TODO: Handle generic protocols
    let isGeneric = !mockableType.genericTypes.isEmpty || mockableType.hasSelfConstraint
    let isProxyable = !(mockableType.kind == .protocol && isGeneric)
    
    return """
    return \(didInvoke) \(BlockTemplate(body: """
    \(FunctionCallTemplate(name: "self.mockingbirdContext.recordInvocation",
                           arguments: [(nil, "$0")]))
    let mkbImpl = \(FunctionCallTemplate(name: "self.mockingbirdContext.stubbing.implementation",
                                         arguments: [("for", "$0")]))
    \(String(lines: [
      callDefault,
      callConvenience,
      callBridgedDefault,
      callBridgedConvenience,
      !isSubclass && !isProxyable ? "" : ForInStatementTemplate(
        item: "mkbTargetBox",
        collection: "self.mockingbirdContext.proxy.targets(for: $0)",
        body: SwitchStatementTemplate(
          controlExpression: "mkbTargetBox.target",
          cases: [
            (".super", isSubclass ? "break" : "return \(callMember(.super))"),
            (".object" + (isProxyable ? "(let mkbObject)" : ""), !isProxyable ? "break" : 
            String(lines: [
              GuardStatementTemplate(
                condition: "var mkbObject = mkbObject as? \(supertype)", body: "break").render(),
              !isOptional || callProxyObject.isEmpty ? callProxyObject :
                GuardStatementTemplate(condition: callProxyObject, body: "break").render(),
              FunctionCallTemplate(
                name: "self.mockingbirdContext.proxy.updateTarget",
                arguments: [(nil, "&mkbObject"), ("in", "mkbTargetBox")]).render(),
              callProxyObject.isEmpty ? "" : "return mkbValue",
            ])),
          ]).render()).render(),
    ]))
    \(IfStatementTemplate(
        condition: """
        let mkbValue = \(FunctionCallTemplate(
                          name: "mockingbirdContext.stubbing.defaultValueProvider.value.provideValue",
                          arguments: [("for", "\(parenthetical: returnType).self")])) as \(returnType)?
        """,
        body: "return mkbValue"))
    \(FunctionCallTemplate(name: "self.mockingbirdContext.stubbing.failTest",
                           arguments: [
                            ("for", "$0"),
                            ("at", "self.mockingbirdContext.sourceLocation")]).render())
    """))
    """
  }
}
