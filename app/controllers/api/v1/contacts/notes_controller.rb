class Api::V1::Contacts::NotesController < Api::V1::Contacts::BaseController
  require_permissions({
    index: 'contacts.read',
    show: 'contacts.read',
    create: 'contacts.update',
    update: 'contacts.update',
    destroy: 'contacts.update'
  })

  before_action :note, except: [:index, :create]

  def index
    notes = @contact.notes.latest.includes(:user)
    success_response(data: notes.map { |note| note_json(note) })
  end

  def show
    success_response(data: note_json(@note))
  end

  def create
    note = @contact.notes.create!(note_params)
    success_response(data: note_json(note), status: :created)
  end

  def update
    @note.update!(note_params)
    success_response(data: note_json(@note))
  end

  def destroy
    @note.destroy!
    success_response(data: {}, message: 'Note deleted successfully')
  end

  private

  def note_json(note)
    note.as_json(
      only: %i[id content created_at updated_at contact_id user_id],
      include: { user: { only: %i[id name email] } }
    )
  end

  def note
    @note ||= @contact.notes.includes(:user).find(params[:id])
  end

  def note_params
    params.require(:note).permit(:content).merge({ contact_id: @contact.id, user_id: Current.user.id })
  end
end
