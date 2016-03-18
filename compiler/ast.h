#include "macros.h"

#include <cassert>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#ifndef CEOS_AST_H
#define CEOS_AST_H

static unsigned str_uid = 0;

#define AST_TYPES(__name, __options...) \
  ENUM_CLASS(__name, __options) \
  EVAL(MAP(DECLARE_CLASS, __options)) \
  EVAL(MAP(DECLARE_CONVERTER, __options))

#define DECLARE_CLASS(__class) class __class;

#define DECLARE_CONVERTER(__class) \
  static std::shared_ptr<AST::__class> as##__class(std::shared_ptr<AST> __n) { \
    assert(__n->type == Type::__class); \
    return std::static_pointer_cast<AST::__class>(__n); \
  }

namespace ceos {
  
  class AST {
    public:
      AST_TYPES(Type, 
        Program,
        Call,
        Number,
        ID,
        String,
        FunctionArgument
      );

      Type type;

      AST(Type t) : type(t) {}

  };

  class AST::Program : public AST {
    public:
      Program() : AST(Type::Program) {}

      void addNode(std::shared_ptr<AST> node) {
        m_nodes.push_back(node);
      }

      std::vector<std::shared_ptr<AST>> nodes() const { return m_nodes; }

      std::vector<std::shared_ptr<AST::Call>> functions;
      std::vector<std::string> strings;

    private:
      std::vector<std::shared_ptr<AST>> m_nodes;
  };

  class AST::Number : public AST {
    public:
      Number(int v) : AST(Type::Number), value(v) {}

      int value;
  };

  class AST::ID : public AST {
    public:
      ID(std::string n, unsigned id) : AST(Type::ID), name(n), uid(id) { }

      std::string name;
      unsigned uid;
  };

  class AST::String : public AST {
    public:
      String(std::string n, unsigned id) : AST(Type::String), name(n), uid(id) { }

      std::string name;
      unsigned uid;
  };

  class AST::Call : public AST {
    public:
      Call() : AST(Type::Call) {}

      std::vector<std::shared_ptr<AST>> arguments;
  };

  class AST::FunctionArgument : public AST {
    public:
      FunctionArgument(unsigned i) : AST(Type::FunctionArgument), index(i) {}

      unsigned index;
  };
}

#endif
