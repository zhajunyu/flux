//
//  AddCategoryView.swift
//  flux
//
//  Created by Codex on 2026/8/10.
//

import SwiftData
import SwiftUI

struct AddCategoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FeedStore.self) private var feedStore

    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Technology"))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($isNameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit(createCategory)
                } header: {
                    Text("Category Name")
                } footer: {
                    Text("Use categories to organize related subscriptions in your feeds list.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.multicolor)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }
                }
            }
            .navigationTitle("New Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: createCategory)
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationSizing(.form)
        .onAppear {
            isNameFieldFocused = true
        }
        .onChange(of: name) {
            errorMessage = nil
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createCategory() {
        guard !trimmedName.isEmpty else { return }

        do {
            try feedStore.createCategory(named: trimmedName, modelContext: modelContext)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
