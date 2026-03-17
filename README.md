# Snowflake Warehouse Administration Modules

This repository contains a collection of reusable Terraform modules designed to simplify Snowflake warehouse administration and governance tasks. Each module is self-contained and can be used independently or combined to build comprehensive Snowflake management solutions.

## About This Project

This is a **modular Terraform project** following a monorepo structure. Each module resides in its own subdirectory and addresses a specific aspect of Snowflake administration. Modules are designed to be composable, maintainable, and follow Terraform best practices.

---

## Available Modules

### 📋 [tagging](./tagging)

**Purpose:** Manages Snowflake column tag associations for data governance and compliance.

**Description:**
The tagging module allows you to apply Snowflake tags to specific columns across multiple tables in a declarative way. It's particularly useful for managing sensitive data classifications (e.g., PHI, PII, PCI) at scale.

**Key Features:**
- Apply tags to multiple columns across multiple tables
- Dynamic resource creation using `for_each`
- Optional tag values (uses Snowflake defaults when omitted)
- Automatic column identifier construction
- Composite key pattern ensures uniqueness

**Use Cases:**
- Mark PHI/PII columns for HIPAA compliance
- Tag sensitive financial data for audit trails
- Classify data for access control policies
- Document column-level metadata

**Example Usage:**
```hcl
module "column_tags" {
  source = "github.com/your-org/SnowflakeWHAdministration-Modules//tagging"

  column_tag_associations = [
    {
      tag_id                     = "PHI"
      tag_value                  = "TRUE"
      table_fully_qualified_name = "DATABASE.SCHEMA.TABLE"
      column                     = "FIRST_NAME"
    },
    {
      tag_id                     = "PII"
      tag_value                  = "TRUE"
      table_fully_qualified_name = "DATABASE.SCHEMA.TABLE"
      column                     = "SSN"
    }
  ]
}
```

**Requirements:**
- Terraform >= 1.3
- Snowflake provider >= 0.80.0

**[View Full Documentation →](./tagging/README.md)**

---

_More modules will be added as they are developed._

## General Requirements

Most modules in this repository require:
- Terraform >= 1.3
- Snowflake provider >= 0.80.0

_Individual modules may have additional requirements. Check each module's README for specific details._

---

## How to Use These Modules

### Using Modules from Git

Each module is located in its own subdirectory. When referencing modules from this Git repository, use the double-slash (`//`) syntax to specify the subdirectory:

```hcl
module "example" {
  source = "github.com/your-org/SnowflakeWHAdministration-Modules//module-name"

  # Module-specific configuration...
}
```

### Local Development

For local development and testing, reference the subdirectory directly using a relative path:

```hcl
module "example" {
  source = "../path/to/SnowflakeWHAdministration-Modules/module-name"

  # Module-specific configuration...
}
```

### Module Documentation

Each module contains:
- **README.md** - Comprehensive documentation with examples
- **examples/** - Working examples demonstrating usage
- **variables.tf** - Input variable definitions
- **outputs.tf** - Output value definitions
- **versions.tf** - Version constraints

---

## Contributing New Modules

When adding a new module to this repository:

1. **Create Module Structure**
   - Create a new subdirectory with a descriptive, lowercase name
   - Use hyphens for multi-word names (e.g., `warehouse-sizing`)

2. **Include Standard Module Files**
   - `main.tf` - Primary resource definitions
   - `variables.tf` - Input variable declarations
   - `outputs.tf` - Output value declarations
   - `versions.tf` - Terraform and provider version constraints
   - `README.md` - Module-specific documentation

3. **Add Examples**
   - Create an `examples/` subdirectory
   - Include at least one working example
   - Document the example in the module's README

4. **Update Documentation**
   - Add a new module section to this root README.md
   - Follow the existing module section format
   - Include purpose, description, key features, use cases, and example
   - Update `CLAUDE.md` if the module introduces new architectural patterns

5. **Follow Best Practices**
   - Use clear, descriptive variable names
   - Include variable descriptions and validation rules
   - Document outputs with descriptions
   - Use locals for complex transformations
   - Include inline comments for non-obvious logic

## Repository Structure

```
SnowflakeWHAdministration-Modules/
├── README.md                    # This file - project overview and module catalog
├── CLAUDE.md                    # AI coding assistant guidance
├── tagging/                     # Column tag association module
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── README.md
│   └── examples/
│       └── phi-tagging/
└── [future-module]/             # Additional modules will follow this structure
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── versions.tf
    ├── README.md
    └── examples/
```

---

## License

Internal use only.
